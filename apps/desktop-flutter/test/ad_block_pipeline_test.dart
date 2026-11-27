import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_block_stats.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/core/m3u8_purify.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/ad_block_stats_service.dart';
import 'package:webhtv_pc/services/ad_block_stats_store.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

/// 6 段正片 + 1 段广告：1/7≈14%，低于规则与启发式各自的单次上限，
/// 这样「删了」或「没删」只由被测开关决定，而不是被安全阈值吞掉。
const _vod = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:6.000,
v/seg-0.ts
#EXTINF:6.000,
v/seg-1.ts
#EXTINF:6.000,
https://ads.example/ad.ts
#EXTINF:6.000,
v/seg-2.ts
#EXTINF:6.000,
v/seg-3.ts
#EXTINF:6.000,
v/seg-4.ts
#EXTINF:6.000,
v/seg-5.ts
#EXT-X-ENDLIST
''';

const _implicitIv = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="k.bin"
#EXTINF:6.000,
v/seg-0.ts
#EXTINF:6.000,
https://ads.example/ad.ts
#EXTINF:6.000,
v/seg-1.ts
#EXT-X-ENDLIST
''';

/// 一次代理请求的结果快照。
class _Fetch {
  _Fetch(this.body, this.stats);
  final String body;
  final AdBlockStats stats;
}

void main() {
  late Directory temp;
  late HttpServer upstream;
  var served = _vod;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ad-block-pipeline-');
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final bytes = utf8.encode(served);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          'application/vnd.apple.mpegurl',
        )
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
  });

  tearDown(() async {
    await upstream.close(force: true);
    await temp.delete(recursive: true);
  });

  final cleanEvents = <int>[];

  Future<_Fetch> fetch({
    AdRuleSet rules = const AdRuleSet.empty(),
    bool heuristic = false,
    String manifest = _vod,
  }) async {
    served = manifest;
    final log = LogService();
    final store = AdBlockStatsStore(path: '${temp.path}/stats.json', log: log);
    final service = AdBlockStatsService(store: store);
    final proxy =
        LocalProxyServer(
            log: log,
            policy: const ProxyTargetPolicy(allowLoopback: true),
          )
          ..adBlockStats = service
          ..adBlockContext = () => const AdBlockContext(
            siteKey: 'fixture',
            siteName: '夹具站',
            pipeline: 'HLS',
          );
    proxy.setAdRules(rules);
    proxy.setAdBlockHeuristic(heuristic);
    cleanEvents.clear();
    proxy.onAdBlockClean = (result, fingerprint) {
      cleanEvents.add(result.removedSegments);
    };
    final client = HttpClient();
    try {
      await proxy.start();
      final session = proxy.sessions.create(
        siteKey: 'fixture',
        allowedHosts: {'127.0.0.1'},
      );
      final target = Uri.parse(
        'http://127.0.0.1:${upstream.port}/vod/main.m3u8',
      );
      final request = await client.getUrl(
        Uri.parse(proxy.urlFor(session, target)),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return _Fetch(body, store.stats);
    } finally {
      client.close(force: true);
      await proxy.stop();
    }
  }

  test('规则命中时清单少一段，统计记一条并带上站点归属', () async {
    final result = await fetch(
      rules: const AdRuleSet(adHosts: ['ads.example']),
    );
    expect(HlsPlaylistShape.parse(result.body).segments, 6);
    expect(result.stats.totalBlocked, 1);
    expect(result.stats.blockLogs.single.adDomain, 'ads.example');
    expect(result.stats.blockLogs.single.siteName, '夹具站');
    expect(result.stats.ruleCounts, {kAdHostRuleId: 1});
    expect(cleanEvents, [1], reason: '拦到广告要发一次 UI 事件（提示用），回退或没删就不发');
  });

  test('没有规则时原样转发，不删除任何分片', () async {
    final result = await fetch();
    expect(HlsPlaylistShape.parse(result.body).segments, 7);
    expect(result.stats.totalBlocked, 0);
    expect(cleanEvents, isEmpty);
  });

  test('启发式默认关闭；显式开启后才兜底删除少数派地址', () async {
    final off = await fetch();
    expect(HlsPlaylistShape.parse(off.body).segments, 7);
    final on = await fetch(heuristic: true);
    expect(HlsPlaylistShape.parse(on.body).segments, 6);
    expect(on.stats.totalBlocked, 1);
    expect(
      on.stats.ruleCounts.keys,
      contains(kPurifyLevelMinorityUrl),
      reason: '启发式删的段要按「哪一级」记账，统计页与日志都靠它',
    );
  });

  test('安全回退的请求不记账：隐式 IV 清单原样放行', () async {
    final result = await fetch(
      rules: const AdRuleSet(adHosts: ['ads.example']),
      manifest: _implicitIv,
    );
    expect(HlsPlaylistShape.parse(result.body).segments, 3);
    expect(result.stats.totalBlocked, 0);
  });
}
