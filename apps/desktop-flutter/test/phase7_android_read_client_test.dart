/// Phase 7 · 安卓读取客户端与降级链（`docs/phase7/design/01` §4.1、`design/04` S14–S16、S30–S33）。
///
/// 用**真实 HTTP**（本文件自建 `HttpServer` 当假安卓）+ 真实 `http.Client`，
/// 因此本文件**不得出现 `testWidgets`**（否则整个 isolate 会被装上 mock HTTP
/// 拦截，真实请求静默失效）。
///
/// 覆盖四类契约：
/// 1. S14 请求形态（URL、`Host` 头、`siteKey` 参数）；
/// 2. S15/S16 404 不算失败、能力探测与降级分类；
/// 3. S30–S33 `episodeId` 优先、空数组≠端点缺失、`updatedAt` 降级；
/// 4. 2026-10-17 实测发现的 `updatedAt` 不可靠 + 内容等价幂等兜底。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/android_read_client.dart';
import 'package:webhtv_pc/services/log_service.dart';

/// 假安卓：可编程的只读端点。
class _FakeAndroid {
  _FakeAndroid._(this._server, this.base);

  final HttpServer _server;
  final String base;

  /// 记录收到的请求（路径 + 查询 + Host 头），供 S14 断言。
  final List<({String path, Map<String, String> query, String? host})> requests =
      [];

  /// `/api/playback/history` 的状态码（null 表示端点不存在）。
  ///
  /// **端点不存在时默认模拟真机行为**：安卓 `Nano.serve()` 对未匹配路径
  /// 落到 `getAssets()`，NanoHTTPD 对缺失资产返回
  /// `200 + application/octet-stream + 空体`（**不是 404**）。
  /// 设 `missingAsOctetStream = false` 可改为返回 404，用于对照。
  int? historyStatus = 200;

  /// 端点不存在时是否模拟真机的 200+octet-stream（默认 true）。
  bool missingAsOctetStream = true;

  /// `/api/playback/history` 的响应体（JSON 对象）。
  Object? historyBody = const {'siteKey': 'x', 'items': [], 'total': 0};

  /// `/api/playback/current` 的状态码（null 表示端点不存在 → 404）。
  int? currentStatus = 404;

  Object? currentBody;

  /// `/manage/session` 的状态码与响应体。
  int? manageStatus = 404;
  Object? manageBody;

  static Future<_FakeAndroid> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeAndroid._(
      server,
      'http://127.0.0.1:${server.port}',
    );
    unawaited(fake._listen());
    return fake;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _listen() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add((
      path: path,
      query: request.uri.queryParameters,
      host: request.headers.value('host'),
    ));

    final (status, body) = switch (path) {
      '/api/playback/history' => (historyStatus, historyBody),
      '/api/playback/current' => (currentStatus, currentBody),
      '/manage/session' => (manageStatus, manageBody),
      _ => (null, null),
    };

    if (status == null) {
      if (missingAsOctetStream) {
        // 真机行为：资产回退 → 200 + octet-stream + 空体。
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'octet-stream');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    if (body != null) request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

/// 一个 64 位十六进制形态的集指纹（与安卓 `episodeId` 的实际形态一致）。
///
/// 不用 `'a' * 64`：默认参数位置要求常量表达式，而 `*` 不能在常量里用。
const String kEpisodeIdA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String kEpisodeIdB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 构造一条安卓 `/api/playback/history` 的记录（`apiSafe()` 字段集）。
///
/// **刻意不含 `createTime`/`updatedAt`**：这是 2026-10-17 真机实测的形态
/// （`design/01` §4.1「阻塞性发现」）。
Map<String, Object?> androidRecord({
  String siteKey = 'CupFox',
  String vodId = '/video/104339.html',
  String vodName = '扫毒风暴',
  String flag = '线路1',
  String episodeName = '第01集',
  String? episodeId = kEpisodeIdA,
  int positionMs = 855470,
  int durationMs = 2787160,
  int? timestamp,
  int? createTime,
  int? updatedAt,
}) => {
  'schema': 'webhtv.playback.v1',
  'historyKey': '$siteKey@@@$vodId@@@1',
  'siteKey': siteKey,
  'vodId': vodId,
  'vodName': vodName,
  'vodPic': '',
  'flag': flag,
  'sourceBindingKey': '线路1#0',
  'episodeName': episodeName,
  'episodeId': ?episodeId,
  'positionMs': positionMs,
  'durationMs': durationMs,
  'progress': durationMs == 0 ? 0.0 : positionMs / durationMs,
  'speed': 1.0,
  'speedOverride': false,
  'completed': false,
  'state': 'idle',
  'timestamp': ?timestamp,
  'createTime': ?createTime,
  'updatedAt': ?updatedAt,
};

void main() {
  late _FakeAndroid fake;
  late AndroidReadClient client;

  setUp(() async {
    fake = await _FakeAndroid.start();
    client = AndroidReadClient(log: LogService());
  });

  tearDown(() async {
    client.close();
    await fake.stop();
  });

  group('S14 · 请求形态（design/01 §4.1）', () {
    test('打 /api/playback/history 并带 siteKey 与 limit', () async {
      fake.historyBody = {'siteKey': 'CupFox', 'items': [], 'total': 0};
      await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
        limit: 7,
      );

      final request = fake.requests.last;
      expect(request.path, '/api/playback/history');
      expect(request.query['siteKey'], 'CupFox');
      expect(request.query['limit'], '7');
    });

    test('显式设置 Host 头（模拟器 NAT 场景必需）', () async {
      await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      final request = fake.requests.last;
      // `Host` 必须是 host:port，与 T4 桥接同一约定。
      expect(request.host, isNotNull);
      expect(request.host, contains(':'));
    });

    test('降级时打 /api/playback/current 且不带 limit', () async {
      fake.currentStatus = 200;
      fake.currentBody = androidRecord();
      await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.currentOnly,
      );

      final request = fake.requests.last;
      expect(request.path, '/api/playback/current');
      expect(request.query['siteKey'], 'CupFox');
      expect(request.query.containsKey('limit'), isFalse);
    });

    test('siteKey 含特殊字符时正确编码', () async {
      await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'a b&c=d',
        capability: RealtimePullCapability.history,
      );
      expect(fake.requests.last.query['siteKey'], 'a b&c=d');
    });
  });

  group('S15/S16 · 能力探测与降级（design/01 §4.1）', () {
    test('history 返回 200 → 完整能力', () async {
      fake.historyStatus = 200;
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.history);
      expect(probe.historyStatusCode, 200);
    });

    test('S33 · history 返回 200 空数组仍算可用（不得当端点缺失）', () async {
      // 这是回归靶子：把 200 空数组当 404 会让「所有站点都没看过」的用户
      // 被永久降级到 currentOnly。
      fake.historyStatus = 200;
      fake.historyBody = const {'siteKey': '__webhtv_probe__', 'items': [], 'total': 0};
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.history);
    });

    test('history 返回 400 也算端点存在（参数不对而非端点缺失）', () async {
      fake.historyStatus = 400;
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.history);
      expect(probe.historyStatusCode, 400);
    });

    test('S16 · history 不存在而 current 存在 → currentOnly', () async {
      fake.historyStatus = null; // 端点不存在（真机形态：200+octet-stream）
      fake.currentStatus = 404; // 端点存在但未播放
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.currentOnly);
      expect(probe.historyResult, EndpointProbeResult.missing);
      expect(probe.currentResult, EndpointProbeResult.notFound);
    });

    test('两者都不可用 → unsupported', () async {
      fake.historyStatus = null;
      fake.currentStatus = null;
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.unsupported);
    });

    test('第二种阻塞性发现 · 端点不存在时真机返回 200+octet-stream', () async {
      // 真机实测：安卓 Nano.serve() 对未匹配路径落到 getAssets()，
      // NanoHTTPD 对缺失资产返回 200 + application/octet-stream + 空体。
      // 若只看状态码（200），会把「端点不存在」当成「存在且无数据」，
      // 于是旧版安卓上路径 A 会“探测成功”但每次读取都静默拿到空结果。
      fake.historyStatus = null;
      fake.currentStatus = null;
      final probe = await client.probePullCapability(fake.base);
      expect(
        probe.capability,
        RealtimePullCapability.unsupported,
        reason: '200+octet-stream 必须归为端点不存在',
      );
      expect(probe.historyStatusCode, 200, reason: '状态码确实是 200（陷阱所在）');
      expect(probe.historyResult, EndpointProbeResult.missing);
    });

    test('对照：端点不存在但返回 404 时也归 missing', () async {
      fake.missingAsOctetStream = false;
      fake.historyStatus = null;
      fake.currentStatus = null;
      final probe = await client.probePullCapability(fake.base);
      expect(probe.capability, RealtimePullCapability.unsupported);
    });

    test('探测用不存在的 siteKey，不误读真实站点数据', () async {
      await client.probePullCapability(fake.base);
      expect(fake.requests.first.query['siteKey'], '__webhtv_probe__');
      expect(fake.requests.first.query['limit'], '1');
    });

    test('unsupported 时 readHistory 直接报错（不静默返回空）', () async {
      await expectLater(
        client.readHistory(
          deviceBase: fake.base,
          siteKey: 'CupFox',
          capability: RealtimePullCapability.unsupported,
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.realtimePullUnsupported,
          ),
        ),
      );
    });
  });

  group('S15 · 404 与空数组的语义（P5）', () {
    test('S15 · 降级端点 404 → 空结果，不抛错（未播放是合法形态）', () async {
      fake.currentStatus = 404;
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.currentOnly,
      );
      expect(result.items, isEmpty);
      expect(result.failures, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('history 端点返回空数组 → 空结果且能力仍为 history', () async {
      fake.historyBody = {'siteKey': 'CupFox', 'items': [], 'total': 0};
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items, isEmpty);
      expect(result.endpoint, RealtimePullCapability.history);
    });

    test('history 端点不存在（未探测就调用）→ 报 unsupported 而非空结果', () async {
      fake.historyStatus = null;
      await expectLater(
        client.readHistory(
          deviceBase: fake.base,
          siteKey: 'CupFox',
          capability: RealtimePullCapability.history,
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.realtimePullUnsupported,
          ),
        ),
      );
    });

    test('端点不存在时真机返回 200+octet-stream → 不得当成空结果', () async {
      // 这是关键回归：若 `_get` 只看状态码，这里会返回 200 空体，
      // 调用方会以为「该站点没记录」而静默不同步。
      fake.historyStatus = null;
      await expectLater(
        client.readHistory(
          deviceBase: fake.base,
          siteKey: 'CupFox',
          capability: RealtimePullCapability.history,
        ),
        throwsA(isA<AppError>()),
      );
    });

    test('5xx → realtimePartialFailure 且可重试', () async {
      fake.historyStatus = 500;
      await expectLater(
        client.readHistory(
          deviceBase: fake.base,
          siteKey: 'CupFox',
          capability: RealtimePullCapability.history,
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.realtimePartialFailure)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('S30/S31 · 记录映射（design/01 §4.1）', () {
    test('S30 · episodeId 字段优先，不被集名覆盖', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(episodeId: kEpisodeIdB, episodeName: '第01集'),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items.single.episodeId, kEpisodeIdB);
      expect(result.items.single.raw['_episodeIdSource'], 'field');
    });

    test('缺 episodeId 字段 → 用 episodeName 兜底并留痕', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [androidRecord(episodeId: null, episodeName: '第03集')],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items.single.episodeId, '第03集');
      expect(result.items.single.raw['_episodeIdSource'], 'episodeName');
    });

    test('两者都空 → 不合并，计入 failures（宁可不合，不可错合）', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [androidRecord(episodeId: null, episodeName: '')],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items, isEmpty);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.reason, contains('都为空'));
    });

    test('缺 historyKey → 计入 failures 而不是猜造记录', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          {'vodName': '扫毒风暴', 'episodeName': '第01集'},
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items, isEmpty);
      expect(result.failures.single.reason, contains('historyKey'));
    });

    test('缺 vodName → 计入 failures', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          {
            'historyKey': 'CupFox@@@/v/1@@@1',
            'episodeName': '第01集',
          },
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.failures.single.reason, contains('vodName'));
    });

    test('字段直传：positionMs/durationMs 不换算', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(positionMs: 855470, durationMs: 2787160),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items.single.positionMs, 855470);
      expect(result.items.single.durationMs, 2787160);
    });

    test('historyKey 切出 siteKey/vodId/cid', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(siteKey: 'CupFox', vodId: '/video/104339.html'),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      final item = result.items.single;
      expect(item.siteKey, 'CupFox');
      expect(item.vodId, '/video/104339.html');
      expect(item.cid, 1);
    });

    test('降级端点返回单条记录（不是数组）也能解析', () async {
      fake.currentStatus = 200;
      fake.currentBody = androidRecord(episodeName: '第05集');
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.currentOnly,
      );
      expect(result.items, hasLength(1));
      expect(result.items.single.episodeName, '第05集');
    });
  });

  group('阻塞性发现 · updatedAt 不可靠（design/01 §4.1）', () {
    test('只有 timestamp（真机实测形态）→ 标记降级', () async {
      // 真机实测：4 条记录的 timestamp 全落在 30ms 内，而库里真实 createTime
      // 跨度 16 小时。用它当 updatedAt 会让「旧不覆盖新」失效。
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(timestamp: 1792220502225),
          androidRecord(vodId: '/v/2', timestamp: 1792220502234),
        ],
        'total': 2,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.updatedAtSource, UpdatedAtSource.timestamp);
      expect(result.items, hasLength(2));
      expect(
        result.items.first.raw['_updatedAtSource'],
        'timestamp',
        reason: '必须留痕来源，否则降级不可见',
      );
    });

    test('有 createTime 时优先于 timestamp（可靠）', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(createTime: 1791975857695, timestamp: 1792220502225),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.updatedAtSource, UpdatedAtSource.createTime);
      expect(result.items.single.updatedAt, 1791975857695);
    });

    test('有 updatedAt 时优先于 createTime（安卓修复后的形态）', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(
            updatedAt: 1791975857695,
            createTime: 1791975000000,
            timestamp: 1792220502225,
          ),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.updatedAtSource, UpdatedAtSource.updatedAt);
      expect(result.items.single.updatedAt, 1791975857695);
    });

    test('整批取「最差」来源：只要有一条不可靠就披露', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(updatedAt: 1791975857695),
          androidRecord(vodId: '/v/2', timestamp: 1792220502234),
        ],
        'total': 2,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.updatedAtSource, UpdatedAtSource.timestamp);
    });

    test('时间戳不可靠时的幂等兜底：内容等价 → 跳过', () async {
      // 本地已有同一条且进度相同 → 即使 timestamp 每轮都变，也不重复应用。
      final existing = SyncHistoryItem(
        siteKey: 'CupFox',
        vodId: '/video/104339.html',
        vodName: '扫毒风暴',
        flag: '线路1',
        episodeName: '第01集',
        episodeId: kEpisodeIdA,
        positionMs: 855470,
        durationMs: 2787160,
        updatedAt: 1,
      );
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(
            positionMs: 855470,
            durationMs: 2787160,
            timestamp: 1792220502225,
          ),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
        localByMatchKey: {existing.matchKey: existing},
      );
      expect(result.items, isEmpty, reason: '内容等价应被跳过');
      expect(result.skippedAsUnchanged, 1);
    });

    test('进度变化时**不**跳过（否则用户进度永远同步不过来）', () async {
      final existing = SyncHistoryItem(
        siteKey: 'CupFox',
        vodId: '/video/104339.html',
        vodName: '扫毒风暴',
        flag: '线路1',
        episodeName: '第01集',
        episodeId: kEpisodeIdA,
        positionMs: 100,
        durationMs: 2787160,
        updatedAt: 1,
      );
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(
            positionMs: 855470,
            durationMs: 2787160,
            timestamp: 1792220502225,
          ),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
        localByMatchKey: {existing.matchKey: existing},
      );
      expect(result.items, hasLength(1));
      expect(result.skippedAsUnchanged, 0);
    });

    test('本地不存在时不跳过（首次同步必须能插进去）', () async {
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [androidRecord(timestamp: 1792220502225)],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
      );
      expect(result.items, hasLength(1));
      expect(result.skippedAsUnchanged, 0);
    });

    test('时间戳可靠时不做内容等价跳过（交给合并裁决）', () async {
      final existing = SyncHistoryItem(
        siteKey: 'CupFox',
        vodId: '/video/104339.html',
        vodName: '扫毒风暴',
        flag: '线路1',
        episodeName: '第01集',
        episodeId: kEpisodeIdA,
        positionMs: 855470,
        durationMs: 2787160,
        updatedAt: 1,
      );
      fake.historyBody = {
        'siteKey': 'CupFox',
        'items': [
          androidRecord(updatedAt: 999, positionMs: 855470, durationMs: 2787160),
        ],
        'total': 1,
      };
      final result = await client.readHistory(
        deviceBase: fake.base,
        siteKey: 'CupFox',
        capability: RealtimePullCapability.history,
        localByMatchKey: {existing.matchKey: existing},
      );
      expect(result.items, hasLength(1));
      expect(result.skippedAsUnchanged, 0);
    });
  });

  group('readManageSession（保活端点，design/02 §3.2）', () {
    test('端点存在时返回字段', () async {
      fake.manageStatus = 200;
      fake.manageBody = {
        'running': true,
        'serverRunning': true,
        'wakeLock': true,
        'wifiLock': false,
        'batteryOptimized': true,
        'backgroundGuide': '请在设置中允许后台运行',
      };
      final session = await client.readManageSession(fake.base);
      expect(session, isNotNull);
      expect(session!['running'], isTrue);
      expect(session['batteryOptimized'], isTrue);
      expect(session['backgroundGuide'], '请在设置中允许后台运行');
    });

    test('端点不存在（老版本安卓）→ null，交给调用方降级', () async {
      fake.manageStatus = null;
      expect(await client.readManageSession(fake.base), isNull);
    });
  });

  group('降级状态汇总（design/01 §4.1 的 P5 披露）', () {
    test('全部可靠时不需披露', () {
      const degradation = RealtimePullDegradation.none();
      expect(degradation.needsDisclosure, isFalse);
      expect(degradation.disclosureError, isNull);
    });

    test('timestamp 降级 → 需披露且分类正确', () {
      const degradation = RealtimePullDegradation(
        capability: RealtimePullCapability.history,
        updatedAtSource: UpdatedAtSource.timestamp,
        recordCount: 4,
        skippedAsUnchanged: 0,
      );
      expect(degradation.needsDisclosure, isTrue);
      expect(
        degradation.disclosureError!.kind,
        AppErrorKind.realtimePullTimestampUnreliable,
      );
    });

    test('能力降级的优先级高于时间戳（前者会丢记录）', () {
      const degradation = RealtimePullDegradation(
        capability: RealtimePullCapability.currentOnly,
        updatedAtSource: UpdatedAtSource.timestamp,
        recordCount: 1,
        skippedAsUnchanged: 0,
      );
      expect(
        degradation.disclosureError!.kind,
        AppErrorKind.realtimePullDegraded,
      );
    });

    test('describe 含全部关键字段（证据落盘用）', () {
      const degradation = RealtimePullDegradation(
        capability: RealtimePullCapability.currentOnly,
        updatedAtSource: UpdatedAtSource.timestamp,
        recordCount: 3,
        skippedAsUnchanged: 2,
      );
      final text = degradation.describe();
      expect(text, contains('capability=currentOnly'));
      expect(text, contains('updatedAt=timestamp'));
      expect(text, contains('records=3'));
      expect(text, contains('skippedUnchanged=2'));
    });
  });

  group('时间戳解析优先级（纯逻辑）', () {
    test('updatedAt > createTime > timestamp', () {
      expect(
        resolveUpdatedAt({'updatedAt': 3, 'createTime': 2, 'timestamp': 1}).source,
        UpdatedAtSource.updatedAt,
      );
      expect(
        resolveUpdatedAt({'createTime': 2, 'timestamp': 1}).source,
        UpdatedAtSource.createTime,
      );
      expect(
        resolveUpdatedAt({'timestamp': 1}).source,
        UpdatedAtSource.timestamp,
      );
      expect(resolveUpdatedAt({}).source, UpdatedAtSource.none);
    });

    test('字符串数字也能解析', () {
      final resolved = resolveUpdatedAt({'updatedAt': '1791975857695'});
      expect(resolved.value, 1791975857695);
      expect(resolved.source, UpdatedAtSource.updatedAt);
    });

    test('0 与负数视为无值（不当作有效时间戳）', () {
      expect(resolveUpdatedAt({'updatedAt': 0}).source, UpdatedAtSource.none);
      expect(resolveUpdatedAt({'updatedAt': -5}).source, UpdatedAtSource.none);
    });

    test('isReliable 只认 updatedAt 与 createTime', () {
      expect(
        resolveUpdatedAt({'updatedAt': 1}).isReliable,
        isTrue,
      );
      expect(
        resolveUpdatedAt({'createTime': 1}).isReliable,
        isTrue,
      );
      expect(
        resolveUpdatedAt({'timestamp': 1}).isReliable,
        isFalse,
      );
      expect(resolveUpdatedAt({}).isDegraded, isTrue);
    });
  });

  group('内容等价判定（纯逻辑）', () {
    test('三项全等 → 等价', () {
      expect(
        isSameProgress(
          positionMsA: 100,
          durationMsA: 200,
          completedA: false,
          positionMsB: 100,
          durationMsB: 200,
          completedB: false,
        ),
        isTrue,
      );
    });

    test('任一项不同 → 不等价', () {
      bool same({int p = 100, int d = 200, bool c = false}) => isSameProgress(
        positionMsA: 100,
        durationMsA: 200,
        completedA: false,
        positionMsB: p,
        durationMsB: d,
        completedB: c,
      );
      expect(same(p: 101), isFalse);
      expect(same(d: 201), isFalse);
      expect(same(c: true), isFalse);
    });

    test('shouldSkipAsUnchanged 要求本地已存在', () {
      expect(shouldSkipAsUnchanged(localExists: true, sameProgress: true), isTrue);
      expect(shouldSkipAsUnchanged(localExists: false, sameProgress: true), isFalse);
      expect(shouldSkipAsUnchanged(localExists: true, sameProgress: false), isFalse);
    });
  });
}
