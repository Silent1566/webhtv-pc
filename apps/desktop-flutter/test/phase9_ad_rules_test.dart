import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  Uri playlist(String url) => Uri.parse(url);

  const manifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.0,
https://cdn.good/1.ts
#EXTINF:5.0,
https://ads.example/ad1.ts
#EXTINF:10.0,
https://cdn.good/2.ts
#EXT-X-ENDLIST
''';

  group('配置解析（P1-1）', () {
    test('ads 接受域名与 URL，hlsRules 过滤非法条目', () {
      final config = AppConfig(
        ads: const ['ads.example', 'https://track.example/path?x=1', '', 42],
        hlsRules: const [
          {
            'id': 'r1',
            'playlistHostSuffixes': ['cdn.good'],
            'hostSuffixes': ['ads.example'],
            'minimumSignals': 1,
          },
          {
            'id': 'bad-min',
            'playlistHostSuffixes': ['cdn.good'],
            'hostSuffixes': ['ads.example'],
            'minimumSignals': 9,
          },
          {
            'id': 'incomplete-duration',
            'playlistHostSuffixes': ['cdn.good'],
            'minDuration': 5,
          },
        ],
      );
      final rules = AdRuleSet.fromConfig(config);
      expect(rules.adHosts, ['ads.example', 'track.example']);
      expect(rules.hlsRules.map((r) => r.id), ['r1']);
      expect(rules.isAdHost('ads.example'), isTrue);
      expect(rules.isAdHost('sub.ads.example'), isTrue);
      expect(rules.isAdHost('good.example'), isFalse);
    });
  });

  group('HLS 清洗（P1-1）', () {
    test('无规则时原样返回', () {
      final result = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet.empty(),
      );
      expect(result.changed, isFalse);
      expect(result.text, manifest);
    });

    test('ads 主机命中：删除分片与分片级标签', () {
      final result = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.removedSegments, 1);
      expect(result.text.contains('ads.example'), isFalse);
      expect(result.text.contains('cdn.good/1.ts'), isTrue);
      expect(result.text.contains('cdn.good/2.ts'), isTrue);
      expect(result.text.contains('#EXT-X-ENDLIST'), isTrue);
    });

    test('规则只在清单主机范围内生效', () {
      const rule = HlsAdRule(
        id: 'r1',
        playlistHostSuffixes: ['other.example'],
        hostSuffixes: ['ads.example'],
        minimumSignals: 1,
      );
      final result = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [rule]),
      );
      expect(result.changed, isFalse);
      expect(result.text, manifest);
    });

    test('分片主机后缀 + 清单范围：命中删除', () {
      const rule = HlsAdRule(
        id: 'r1',
        playlistHostSuffixes: ['cdn.good'],
        hostSuffixes: ['ads.example'],
        minimumSignals: 1,
      );
      final result = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [rule]),
      );
      expect(result.removedSegments, 1);
      expect(result.text.contains('ads.example'), isFalse);
    });

    test('时长 + 正则两个信号要求 minimumSignals=2', () {
      const rule = HlsAdRule(
        id: 'r2',
        playlistHostSuffixes: ['cdn.good'],
        segmentUrlRegex: [r'/ad\d+\.ts'],
        minDuration: 4,
        maxDuration: 6,
        minimumSignals: 2,
      );
      final result = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [rule]),
      );
      expect(result.removedSegments, 1);

      // 只满足时长（5s）但 URL 不匹配 → 不删。
      const onlyDuration = HlsAdRule(
        id: 'r3',
        playlistHostSuffixes: ['cdn.good'],
        segmentUrlRegex: [r'/never\.ts'],
        minDuration: 4,
        maxDuration: 6,
        minimumSignals: 2,
      );
      final kept = cleanHlsPlaylist(
        text: manifest,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [onlyDuration]),
      );
      expect(kept.changed, isFalse);
    });

    test('跨域信号 + 不连续信号', () {
      const text = '''
#EXTM3U
#EXTINF:10,
https://cdn.good/1.ts
#EXT-X-DISCONTINUITY
#EXTINF:10,
https://ad.other/2.ts
#EXTINF:10,
https://cdn.good/3.ts
''';
      const rule = HlsAdRule(
        id: 'r4',
        playlistHostSuffixes: ['cdn.good'],
        requireDiscontinuity: true,
        requireCrossDomain: true,
        minimumSignals: 2,
      );
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [rule]),
      );
      expect(result.removedSegments, 1);
      expect(result.text.contains('ad.other'), isFalse);
    });

    test('删除广告分片时保留 EXT-X-KEY（不破坏后续解密）', () {
      const text = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://key.example/k"
#EXTINF:5,
https://ads.example/ad.ts
#EXTINF:10,
https://cdn.good/1.ts
''';
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.removedSegments, 1);
      expect(result.text.contains('#EXT-X-KEY'), isTrue);
      expect(result.text.contains('cdn.good/1.ts'), isTrue);
    });
  });
}
