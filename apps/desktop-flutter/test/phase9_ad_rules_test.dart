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
#EXT-X-ENDLIST
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
#EXT-X-KEY:METHOD=AES-128,URI="https://key.example/k",IV=0x00000000000000000000000000000001
#EXTINF:5,
https://ads.example/ad.ts
#EXTINF:10,
https://cdn.good/1.ts
#EXTINF:10,
https://cdn.good/2.ts
#EXTINF:10,
https://cdn.good/3.ts
#EXTINF:10,
https://cdn.good/4.ts
#EXT-X-ENDLIST
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

  group('安全上限与回退（对齐安卓 HlsManifestCleaner）', () {
    String playlistWith(int segments, String adUrl, {double duration = 10}) {
      final buffer = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < segments; i++) {
        buffer
          ..writeln('#EXTINF:$duration,')
          ..writeln('https://cdn.good/$i.ts');
      }
      buffer
        ..writeln('#EXTINF:$duration,')
        ..writeln(adUrl)
        ..writeln('#EXT-X-ENDLIST');
      return buffer.toString();
    }

    test('删除比例超过 35% 时整次回退，原文不变', () {
      // 10 段里 4 段命中 = 40% > 35%。
      final text = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 10; i++) {
        text
          ..writeln('#EXTINF:10,')
          ..writeln(
            i.isEven ? 'https://cdn.good/$i.ts' : 'https://ads.example/$i.ts',
          );
      }
      text.writeln('#EXT-X-ENDLIST');
      final result = cleanHlsPlaylist(
        text: text.toString(),
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandoned, isTrue);
      expect(result.abandonReason, contains('35%'));
      expect(result.text, text.toString());
    });

    test('删除时长超过 90 秒时整次回退', () {
      final text = playlistWith(20, 'https://ads.example/ad.ts', duration: 100);
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('90 秒'));
    });

    test('全部命中判定为广告时回退，绝不清空清单', () {
      const text = '''
#EXTM3U
#EXTINF:10,
https://ads.example/a.ts
#EXTINF:10,
https://ads.example/b.ts
#EXT-X-ENDLIST
''';
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('所有分片'));
    });

    test('BYTERANGE 清单直接放弃', () {
      const text = '''
#EXTM3U
#EXT-X-BYTERANGE:1000@0
#EXTINF:10,
https://cdn.good/0.ts
#EXTINF:10,
https://ads.example/ad.ts
#EXT-X-ENDLIST
''';
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('BYTERANGE'));
    });

    test('低延迟 HLS 清单直接放弃', () {
      const text = '''
#EXTM3U
#EXT-X-PART:DURATION=0.5,URI="p0.ts"
#EXTINF:2,
https://cdn.good/0.ts
#EXTINF:2,
https://ads.example/ad.ts
#EXT-X-ENDLIST
''';
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('低延迟'));
    });
  });

  group('直播窗口（无 ENDLIST）', () {
    const live = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:120
#EXT-X-DISCONTINUITY-SEQUENCE:3
#EXT-X-DISCONTINUITY
#EXTINF:10,
https://ads.example/ad.ts
#EXTINF:10,
https://cdn.good/1.ts
#EXTINF:10,
https://cdn.good/2.ts
''';

    test('删窗口头部广告并同步递增两个序号', () {
      final result = cleanHlsPlaylist(
        text: live,
        playlistUri: playlist('https://cdn.good/1.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.removedSegments, 1);
      expect(result.text.contains('ads.example'), isFalse);
      expect(result.text.contains('#EXT-X-MEDIA-SEQUENCE:121'), isTrue);
      expect(result.text.contains('#EXT-X-DISCONTINUITY-SEQUENCE:4'), isTrue);
      // 移出窗口的那条 DISCONTINUITY 不该留在新的窗口头。
      expect(
        result.text.contains('#EXT-X-DISCONTINUITY\n'),
        isFalse,
        reason: '窗口头部的 DISCONTINUITY 已由序号递增表达',
      );
      expect(result.text.contains('cdn.good/1.ts'), isTrue);
    });

    test('广告在窗口中间时放弃（无法保持序号语义）', () {
      const middle = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:120
#EXTINF:10,
https://cdn.good/1.ts
#EXTINF:10,
https://ads.example/ad.ts
#EXTINF:10,
https://cdn.good/2.ts
''';
      final result = cleanHlsPlaylist(
        text: middle,
        playlistUri: playlist('https://cdn.good/1.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('窗口头部'));
    });

    test('缺少 MEDIA-SEQUENCE 的直播清单放弃', () {
      const noSequence = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://ads.example/ad.ts
#EXTINF:10,
https://cdn.good/1.ts
#EXTINF:10,
https://cdn.good/2.ts
''';
      final result = cleanHlsPlaylist(
        text: noSequence,
        playlistUri: playlist('https://cdn.good/1.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.changed, isFalse);
      expect(result.abandonReason, contains('MEDIA-SEQUENCE'));
    });
  });

  group('统计口径：按规则计数与删除明细', () {
    const text = '''
#EXTM3U
#EXTINF:4,
https://ads.example/pre.ts
#EXTINF:10,
https://cdn.good/1.ts
#EXTINF:10,
https://cdn.good/2.ts
#EXTINF:10,
https://cdn.good/3.ts
#EXT-X-ENDLIST
''';

    test('ruleCounts / removedDurationSec / removed 明细都对得上', () {
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(adHosts: ['ads.example']),
      );
      expect(result.removedSegments, 1);
      expect(result.removedDurationSec, 4);
      expect(result.ruleCounts, {'ads': 1});
      expect(result.removed, hasLength(1));
      final segment = result.removed.single;
      expect(segment.host, 'ads.example');
      expect(segment.ruleId, 'ads');
      expect(segment.startSeconds, 0);
      expect(segment.durationSec, 4);
      // 明细要能原样落盘再读回（统计持久化用同一份结构）。
      expect(AdRemovedSegment.fromJson(segment.toJson())?.ruleId, 'ads');
    });

    test('规则 id 取代 ads 计入计数', () {
      const rule = HlsAdRule(
        id: 'my-rule',
        playlistHostSuffixes: ['cdn.good'],
        hostSuffixes: ['ads.example'],
        minimumSignals: 1,
      );
      final result = cleanHlsPlaylist(
        text: text,
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: const AdRuleSet(hlsRules: [rule]),
      );
      expect(result.ruleCounts, {'my-rule': 1});
      expect(result.removed.single.ruleId, 'my-rule');
    });
  });

  group('规则正则的安全边界', () {
    test('病态回溯正则的规则被丢弃，清单原样返回', () {
      final rules = HlsAdRule.listFrom([
        {
          'id': 'boom',
          'playlistHostSuffixes': ['cdn.good'],
          'segmentUrlRegex': ['(a+)+b'],
        },
        {
          'id': 'too-long',
          'playlistHostSuffixes': ['cdn.good'],
          'segmentUrlRegex': ['x' * 600],
        },
      ]);
      expect(rules, isEmpty);
      final result = cleanHlsPlaylist(
        text: '''
#EXTM3U
#EXTINF:10,
https://ads.example/ad.ts
#EXT-X-ENDLIST
''',
        playlistUri: playlist('https://cdn.good/main.m3u8'),
        rules: AdRuleSet(hlsRules: rules),
      );
      expect(result.changed, isFalse);
    });

    test('规则本身合法时正常删除', () {
      final rules = HlsAdRule.listFrom([
        {
          'id': 'ok',
          'playlistHostSuffixes': ['cdn.good'],
          'segmentUrlRegex': [r'/ad\d+\.ts'],
        },
      ]);
      expect(rules, hasLength(1));
    });
  });
}
