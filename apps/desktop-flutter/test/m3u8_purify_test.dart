import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/m3u8_purify.dart';

void main() {
  final playlistUri = Uri.parse('https://cdn.good/v/index.m3u8');

  String content(
    String name, {
    String duration = '10.0',
    bool discontinuity = false,
    List<String> tags = const <String>[],
  }) {
    return <String>[
      if (discontinuity) '#EXT-X-DISCONTINUITY',
      ...tags,
      '#EXTINF:$duration,',
      'https://cdn.good/v/$name.ts',
    ].join('\n');
  }

  String segment(
    String url, {
    String duration = '10.0',
    bool discontinuity = false,
    List<String> tags = const <String>[],
  }) {
    return <String>[
      if (discontinuity) '#EXT-X-DISCONTINUITY',
      ...tags,
      '#EXTINF:$duration,',
      url,
    ].join('\n');
  }

  String manifest(Iterable<String> blocks) {
    return <String>[
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      '#EXT-X-TARGETDURATION:10',
      '#EXT-X-MEDIA-SEQUENCE:0',
      ...blocks,
      '#EXT-X-ENDLIST',
      '',
    ].join('\n');
  }

  group('API 与硬边界', () {
    test('PurifyOutcome 的默认值与派生属性', () {
      const outcome = PurifyOutcome(text: 'x');
      expect(outcome.changed, isFalse);
      expect(outcome.abandoned, isFalse);
      expect(outcome.removedSegments, 0);
      expect(outcome.levelCounts, isEmpty);
    });

    test('不以 #EXTM3U 开头：原样返回 + abandonReason', () {
      const input =
          'EXTM3U\n#EXTINF:10.0,\nhttps://cdn.good/v/s1.ts\n#EXT-X-ENDLIST\n';
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.changed, isFalse);
      expect(outcome.abandonReason, contains('#EXTM3U'));
    });

    test('直播清单（缺 ENDLIST）：原样返回，不猜窗口头', () {
      final input = <String>[
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:10',
        content('s1'),
        content('s2'),
        '',
      ].join('\n');
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.changed, isFalse);
      expect(outcome.abandonReason, contains('ENDLIST'));
    });

    test('含 BYTERANGE：原样返回 + abandonReason', () {
      final input = <String>[
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-BYTERANGE:1000@0',
        content('s1'),
        content('s2'),
        '#EXT-X-ENDLIST',
        '',
      ].join('\n');
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.changed, isFalse);
      expect(outcome.abandonReason, contains('BYTERANGE'));
    });

    test('低延迟清单（#EXT-X-PART）：原样返回 + abandonReason', () {
      final input = <String>[
        '#EXTM3U',
        '#EXT-X-VERSION:9',
        '#EXT-X-PART:DURATION=1.0,URI="p0.ts"',
        content('s1'),
        '#EXT-X-ENDLIST',
        '',
      ].join('\n');
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.changed, isFalse);
      expect(outcome.abandonReason, contains('低延迟'));
    });
  });

  group('无标记清单', () {
    test('干净清单原样返回，计数全空', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 6; i++) content('s$i'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.removedSegments, 0);
      expect(outcome.changed, isFalse);
      expect(outcome.abandoned, isFalse);
      expect(outcome.levelCounts, isEmpty);
    });
  });

  group('第 1 级 removeMinorityUrl', () {
    test('正例：少数派域名被删，主导者过半才动手', () {
      final input = manifest(<String>[
        content('s1'),
        content('s2'),
        content('s3'),
        content('s4'),
        segment('https://other.host/v/clip.ts', duration: '5.0'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, isNot(contains('other.host')));
      expect(outcome.text, contains('https://cdn.good/v/s4.ts'));
      expect(outcome.removedSegments, 1);
      expect(outcome.removedDurationSec, 5.0);
      expect(outcome.levelCounts, <String, int>{kPurifyLevelMinorityUrl: 1});
      expect(outcome.abandoned, isFalse);
    });

    test('反例：同一主机+目录不删；两份地址五五开也不删', () {
      final uniform = manifest(<String>[
        for (var i = 1; i <= 6; i++) content('s$i'),
      ]);
      expect(
        purifyM3u8Playlist(
          text: uniform,
          playlistUri: playlistUri,
        ).removedSegments,
        0,
      );

      final split = manifest(<String>[
        content('s1'),
        content('s2'),
        content('s3'),
        segment('https://other.host/v/a.ts'),
        segment('https://other.host/v/b.ts'),
        segment('https://other.host/v/c.ts'),
      ]);
      final outcome = purifyM3u8Playlist(text: split, playlistUri: playlistUri);
      expect(outcome.removedSegments, 0);
      expect(outcome.text, split);
    });

    test('单级删除超过 30%：该级作废，保留原文', () {
      final input = manifest(<String>[
        content('s1'),
        content('s2'),
        content('s3'),
        segment('https://other.host/v/a.ts'),
        segment('https://other.host/v/b.ts'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      // 2/5 = 40% > 30%，整级作废。
      expect(outcome.text, input);
      expect(outcome.removedSegments, 0);
      expect(outcome.levelCounts, isEmpty);
    });
  });

  group('第 2 级 clean', () {
    test('正例：两道 DISCONTINUITY 之间只剩一段', () {
      final input = manifest(<String>[
        content('s1'),
        content('s2'),
        content('s3'),
        content('s4'),
        content('s5'),
        content('s6', duration: '5.0', discontinuity: true),
        content('s7', discontinuity: true),
        content('s8'),
        content('s9'),
        content('s10'),
        content('s11'),
        content('s12'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{kPurifyLevelClean: 1});
      expect(outcome.text, isNot(contains('v/s6.ts')));
      expect(outcome.text, contains('v/s5.ts'));
      expect(outcome.text, contains('v/s7.ts'));
      expect(outcome.removedSegments, 1);
    });

    test('反例：两段一组的缝合块不由 clean 处理', () {
      final input = manifest(<String>[
        content('s1'),
        content('s2'),
        content('s3'),
        content('s4'),
        content('s5'),
        content('s6', discontinuity: true),
        content('s7'),
        content('s8', discontinuity: true),
        content('s9'),
        content('s10'),
        content('s11'),
        content('s12'),
        content('s13'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts.containsKey(kPurifyLevelClean), isFalse);
      expect(outcome.levelCounts[kPurifyLevelDiscontinuityGroups], 2);
    });

    test('正例：0 时长 EXTINF 分片被删', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 4; i++) content('s$i'),
        content('bumper', duration: '0.0'),
        for (var i = 5; i <= 8; i++) content('s$i'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{kPurifyLevelClean: 1});
      expect(outcome.text, isNot(contains('bumper')));
    });
  });

  group('第 3 级 cleanCommonAdMarkers', () {
    test('正例：CUE-OUT ~ CUE-IN 广告块整段删', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 4; i++) content('s$i'),
        content('s5', tags: const <String>['#EXT-X-CUE-OUT:30.0']),
        content('s6', tags: const <String>['#EXT-X-CUE-OUT-CONT:10.0/30.0']),
        content('s7', tags: const <String>['#EXT-X-CUE-IN']),
        for (var i = 8; i <= 10; i++) content('s$i'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{
        kPurifyLevelCommonAdMarkers: 3,
      });
      expect(outcome.text, isNot(contains('CUE-OUT')));
      expect(outcome.text, isNot(contains('CUE-IN')));
      expect(outcome.text, contains('v/s4.ts'));
      expect(outcome.text, contains('v/s8.ts'));
    });

    test('正例：SCTE-35 段、URL 广告词段、广告 DATERANGE 段', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 4; i++) content('s$i'),
        content('s5', tags: const <String>['#EXT-X-SCTE35:CUE="abc"']),
        segment('https://cdn.good/v/midroll.ts'),
        content(
          's7',
          tags: const <String>[
            '#EXT-X-DATERANGE:ID="ad-slot",CLASS="com.apple.hls.interstitial"',
          ],
        ),
        for (var i = 8; i <= 12; i++) content('s$i'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{
        kPurifyLevelCommonAdMarkers: 3,
      });
      expect(outcome.text, isNot(contains('midroll')));
      expect(outcome.text, isNot(contains('DATERANGE')));
    });

    test('反例：非广告 DATERANGE 属性与 URL 片段里的字母组合不误伤', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 5; i++) content('s$i'),
        content(
          's6',
          tags: const <String>[
            '#EXT-X-DATERANGE:ID="LOAD-TRIGGER",CLASS="com.example.timeline"',
          ],
        ),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, isEmpty);
      expect(outcome.text, input);
    });

    test('全段被判广告（>30%）：整级作废，不做「删空」', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 6; i++)
          segment('https://cdn.good/v/midroll-$i.ts'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.removedSegments, 0);
    });
  });

  group('第 4 级 精度/帧率组', () {
    test('正例（精度）：3 位小数且完全一致的短组被删', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 8; i++) content('s$i'),
        content('s9', duration: '9.976', discontinuity: true),
        content('s10', duration: '9.976'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{
        kPurifyLevelDecimalPrecisionGroups: 2,
      });
      expect(outcome.text, isNot(contains('v/s9.ts')));
      expect(outcome.text, contains('v/s8.ts'));
    });

    test('正例（帧率）：短组时长在 ±1 帧内摆动', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 8; i++) content('s$i', duration: '25.0'),
        content('s9', duration: '25.033', discontinuity: true),
        content('s10', duration: '25.0'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{
        kPurifyLevelFrameRateGroups: 2,
      });
      expect(outcome.text, isNot(contains('v/s9.ts')));
    });

    test('反例：时长既不一致也不在 1 帧内 → 精度/帧率两级都不命中', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 8; i++) content('s$i'),
        content('s9', duration: '9.976', discontinuity: true),
        content('s10', duration: '20.5'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(
        outcome.levelCounts.containsKey(kPurifyLevelDecimalPrecisionGroups),
        isFalse,
      );
      expect(
        outcome.levelCounts.containsKey(kPurifyLevelFrameRateGroups),
        isFalse,
      );
      // 由最后一级兜住——它只删「短 + 非主导」的组。
      expect(outcome.levelCounts[kPurifyLevelDiscontinuityGroups], 2);
    });
  });

  group('第 5 级 cleanDiscontinuityGroups', () {
    test('正例：非主导的短不连续组被删', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 8; i++) content('s$i', duration: '12.0'),
        content('s9', duration: '3.0', discontinuity: true),
        content('s10', duration: '3.0'),
        content('s11', duration: '3.0'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.levelCounts, <String, int>{
        kPurifyLevelDiscontinuityGroups: 3,
      });
      expect(outcome.text, isNot(contains('v/s9.ts')));
      expect(outcome.text, contains('v/s8.ts'));
    });

    test('反例：两组一样长（都是 5 段）时不删', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 5; i++) content('s$i'),
        content('s6', discontinuity: true),
        for (var i = 7; i <= 10; i++) content('s$i'),
      ]);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.removedSegments, 0);
      expect(outcome.text, input);
    });
  });

  group('整体保护', () {
    test('累计删除超过原清单 50%：整体回退到原文', () {
      final blocks = <String>[
        for (var i = 1; i <= 30; i++) segment('https://ads.minority/v/m$i.ts'),
        for (var i = 31; i <= 70; i++) content('c$i'),
        for (var i = 71; i <= 91; i++)
          content(
            'c$i',
            tags: <String>[
              if (i == 71) '#EXT-X-CUE-OUT:210.0',
              if (i > 71 && i < 91) '#EXT-X-CUE-OUT-CONT:10.0/210.0',
              if (i == 91) '#EXT-X-CUE-IN',
            ],
          ),
        for (var i = 92; i <= 100; i++) content('c$i'),
      ];
      final input = manifest(blocks);
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      // 第 1 级删 30%（30/100），第 3 级再删 30%（21/70），累计 51% > 50%。
      expect(outcome.text, input);
      expect(outcome.removedSegments, 0);
      expect(outcome.abandoned, isTrue);
      expect(outcome.abandonReason, contains('50%'));
    });

    test('清洗后不可播放（悬空 EXTINF）：整体回退', () {
      final input = <String>[
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXTINF:10.0,',
        'https://cdn.good/v/s1.ts',
        '#EXTINF:10.0,',
        'https://cdn.good/v/s2.ts',
        '#EXTINF:10.0,',
        'https://other.host/v/s3.ts',
        '#EXTINF:10.0,',
        'https://cdn.good/v/s4.ts',
        '#EXTINF:10.0,',
        '#EXT-X-ENDLIST',
        '',
      ].join('\n');
      final outcome = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(outcome.text, input);
      expect(outcome.removedSegments, 0);
      expect(outcome.abandoned, isTrue);
      expect(outcome.abandonReason, contains('可播放'));
    });
  });

  group('幂等', () {
    test('对已清洗输出再跑一次，文本不再变化', () {
      final input = manifest(<String>[
        for (var i = 1; i <= 6; i++) content('s$i'),
        segment('https://other.host/v/a1.ts', discontinuity: true),
        segment('https://other.host/v/a2.ts'),
        content('s9', discontinuity: true),
        content('s10'),
      ]);
      final first = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(first.changed, isTrue);
      expect(first.levelCounts[kPurifyLevelMinorityUrl], 2);
      expect(first.levelCounts[kPurifyLevelDiscontinuityGroups], 2);
      expect(first.removedSegments, 4);

      final second = purifyM3u8Playlist(
        text: first.text,
        playlistUri: playlistUri,
      );
      expect(second.text, first.text);
      expect(second.removedSegments, 0);
      expect(second.changed, isFalse);
    });
  });

  group('R6 safety regressions', () {
    void expectRollback(PurifyOutcome result, String input, String reason) {
      expect(result.text, input);
      expect(result.removedSegments, 0);
      expect(result.removedDurationSec, 0);
      expect(result.levelCounts, isEmpty);
      expect(result.abandonReason, contains(reason));
    }

    test('implicit IV AES-128 and SAMPLE-AES abort exactly', () {
      for (final method in ['AES-128', 'SAMPLE-AES', 'SAMPLE-AES-CTR']) {
        final input = manifest([
          content('s0', tags: ['#EXT-X-KEY:METHOD=$method,URI="key"']),
          content('s1'),
          content('s2'),
          content('s3'),
          segment('https://other.host/v/clip.ts'),
        ]);
        expectRollback(
          purifyM3u8Playlist(text: input, playlistUri: playlistUri),
          input,
          'IV',
        );
      }
    });

    test(
      'ad MAP and even shared MAP abort without rebinding initialization',
      () {
        for (final onAd in [true, false]) {
          final input = manifest([
            content('s0', tags: onAd ? [] : ['#EXT-X-MAP:URI="init.mp4"']),
            content('s1'),
            content('s2'),
            content('s3'),
            segment(
              'https://other.host/v/clip.ts',
              tags: onAd ? ['#EXT-X-MAP:URI="ad-init.mp4"'] : [],
            ),
          ]);
          expectRollback(
            purifyM3u8Playlist(text: input, playlistUri: playlistUri),
            input,
            'MAP',
          );
        }
      },
    );

    test('explicit-IV key rotation without MAP stays playable', () {
      final input = manifest([
        content('s0', tags: ['#EXT-X-KEY:METHOD=AES-128,URI="k0",IV=0x01']),
        content('s1'),
        segment(
          'https://other.host/v/clip.ts',
          tags: ['#EXT-X-KEY:METHOD=AES-128,URI="k1",IV=0x02'],
        ),
        content('s3'),
        content('s4'),
        content('s5'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.abandoned, isFalse);
      expect(result.removedSegments, 1);
      expect(result.text, contains('URI="k0"'));
      expect(
        result.text.indexOf('URI="k1"'),
        lessThan(result.text.indexOf('/s3.ts')),
      );
      expect(
        purifyM3u8Playlist(text: result.text, playlistUri: playlistUri).text,
        result.text,
      );
    });

    test('CUE-OUT before first EXTINF is not lost in header', () {
      final input = manifest([
        content('slot', tags: ['#EXT-X-CUE-OUT:10']),
        content('s1', tags: ['#EXT-X-CUE-IN']),
        for (var i = 2; i <= 9; i++) content('s$i'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.levelCounts[kPurifyLevelCommonAdMarkers], 2);
      expect(result.text, isNot(contains('/slot.ts')));
      expect(result.text, isNot(contains('CUE-OUT')));
    });

    test('persistent DEFINE survives removal of owning segment', () {
      final input = manifest([
        content('s0'),
        content('s1'),
        segment(
          'https://other.host/v/clip.ts',
          tags: ['#EXT-X-DEFINE:NAME="token",VALUE="x"'],
        ),
        content('s3'),
        content('s4'),
        content('s5'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.removedSegments, 1);
      expect(result.text, contains('#EXT-X-DEFINE:NAME="token",VALUE="x"'));
    });

    test('GAP semantics on removed segment cause conservative rollback', () {
      final input = manifest([
        content('s0'),
        content('s1'),
        segment('https://other.host/v/clip.ts', tags: ['#EXT-X-GAP']),
        content('s3'),
        content('s4'),
        content('s5'),
      ]);
      expectRollback(
        purifyM3u8Playlist(text: input, playlistUri: playlistUri),
        input,
        'GAP',
      );
    });

    test('removed boundary separates two equal long content groups', () {
      final input = manifest([
        for (var i = 0; i < 5; i++) content('s$i'),
        segment('https://other.host/v/clip.ts', discontinuity: true),
        for (var i = 6; i < 11; i++) content('s$i'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.removedSegments, 1);
      expect(
        result.text,
        contains(
          '#EXT-X-DISCONTINUITY\n#EXTINF:10.0,\nhttps://cdn.good/v/s6.ts',
        ),
      );
    });
  });

  group('R6 original removal statistics', () {
    test('multi-stage repeated URIs keep original indexes and timeline', () {
      final repeated = segment('https://cdn.good/v/repeat.ts', duration: '5.0');
      final input = manifest([
        content('s0', duration: '3.0'),
        segment('https://other.host/v/clip.ts', duration: '4.0'),
        repeated,
        segment(
          'https://cdn.good/v/repeat.ts',
          duration: '5.0',
          tags: ['#EXT-X-SCTE35:abc'],
        ),
        content('s4', duration: '6.0'),
        content('s5', duration: '7.0'),
        content('s6', duration: '8.0'),
        content('s7', duration: '9.0'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.removedSegments, 2);
      expect(result.removedDurationSec, 9.0);
      expect(result.removed.map((s) => s.originalIndex).toList(), [1, 3]);
      expect(result.removed.map((s) => s.startSeconds).toList(), [3.0, 12.0]);
      expect(result.removed.map((s) => s.durationSec).toList(), [4.0, 5.0]);
      expect(result.removed.map((s) => s.host).toList(), [
        'other.host',
        'cdn.good',
      ]);
      expect(result.removed.map((s) => s.ruleId).toList(), [
        kPurifyLevelMinorityUrl,
        kPurifyLevelCommonAdMarkers,
      ]);
      expect(result.removed.length, result.removedSegments);
      expect(
        result.removed.fold<double>(0, (sum, s) => sum + s.durationSec),
        result.removedDurationSec,
      );
      final byRule = <String, int>{};
      for (final removed in result.removed) {
        byRule[removed.ruleId] = (byRule[removed.ruleId] ?? 0) + 1;
      }
      expect(byRule, result.levelCounts);
      expect(result.text.split('https://cdn.good/v/repeat.ts').length - 1, 1);
      expect(() => result.removed.clear(), throwsUnsupportedError);
      expect(
        () => result.removed.add(
          const PurifyRemovedSegment(
            host: 'x',
            ruleId: 'x',
            startSeconds: 0,
            durationSec: 0,
            originalIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        purifyM3u8Playlist(text: result.text, playlistUri: playlistUri).removed,
        isEmpty,
      );
    });

    test('every original rollback also clears all details', () {
      final inputs = [
        'not m3u8',
        manifest([content('s0')]).replaceFirst('#EXT-X-ENDLIST', ''),
        manifest([
          content('s0', tags: ['#EXT-X-BYTERANGE:10@0']),
        ]),
        manifest([
          content('s0', tags: ['#EXT-X-PART:URI="part.ts"']),
        ]),
        manifest([
          content('s0', tags: ['#EXT-X-MAP:URI="init.mp4"']),
        ]),
        manifest([
          content('s0', tags: ['#EXT-X-KEY:METHOD=AES-128,URI="key"']),
        ]),
        manifest([
          content('s0'),
          content('s1'),
          content('s2'),
          segment('https://other.host/v/s3.ts'),
        ]).replaceFirst('#EXT-X-ENDLIST', '#EXTINF:10,\n#EXT-X-ENDLIST'),
        manifest([
          for (var i = 0; i < 30; i++) segment('https://other.host/v/a$i.ts'),
          for (var i = 30; i < 100; i++)
            content(
              's$i',
              tags: i >= 70 && i <= 90 ? ['#EXT-X-SCTE35:abc'] : [],
            ),
        ]),
      ];
      for (final input in inputs) {
        final r = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
        expect(r.abandoned, isTrue);
        expect(r.text, input);
        expect(r.removedSegments, 0);
        expect(r.removedDurationSec, 0);
        expect(r.levelCounts, isEmpty);
        expect(r.removed, isEmpty);
      }
    });
  });

  group('R6 bounded fixed point', () {
    String chainInput() => manifest([
      for (var i = 0; i < 8; i++) content('s$i'),
      content('g0a', discontinuity: true),
      content('g0b', tags: ['#EXT-X-SCTE35:abc']),
      for (var g = 1; g < 4; g++) ...[
        content('g${g}a', discontinuity: true),
        content('g${g}b'),
      ],
    ]);

    test('chain needing another pass rolls back instead of returning partial output', () {
      final input = chainInput();
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.abandonReason, contains('固定点'));
      expect(result.text, input);
      expect(result.removedSegments, 0);
      expect(result.removedDurationSec, 0);
      expect(result.levelCounts, isEmpty);
      expect(result.removed, isEmpty);
      expect(
        purifyM3u8Playlist(text: result.text, playlistUri: playlistUri).text,
        input,
      );
    });

    test('fixed-point proof across finite short-group samples', () {
      for (var count = 1; count <= 4; count++) {
        for (final duration in ['3.0', '9.976', '25.033', '0.0']) {
          for (final marker in [false, true]) {
            final input = manifest([
              for (var i = 0; i < 8; i++) content('s$i'),
              for (var i = 0; i < count; i++)
                content(
                  'g$i',
                  duration: duration,
                  discontinuity: i == 0,
                  tags: marker && i == count - 1 ? ['#EXT-X-SCTE35:abc'] : [],
                ),
              for (var i = 0; i < 5; i++)
                content('tail$i', discontinuity: i == 0),
            ]);
            final first = purifyM3u8Playlist(
              text: input,
              playlistUri: playlistUri,
            );
            final second = purifyM3u8Playlist(
              text: first.text,
              playlistUri: playlistUri,
            );
            expect(second.text, first.text, reason: '$count/$duration/$marker');
            if (first.changed) expect(second.removedSegments, 0);
          }
        }
      }
    });
  });

  group('R6 malformed metadata rollback', () {
    test('malformed ad URI does not throw or leak partial details', () {
      final input = manifest([
        for (var i = 0; i < 5; i++) content('s$i'),
        segment('https://[ad/clip.ts'),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.abandoned, isTrue);
      expect(result.text, input);
      expect(result.removed, isEmpty);
    });

    test(
      'invalid EXTINF duration cannot corrupt the original statistics timeline',
      () {
        for (final duration in ['NaN', 'Infinity', '-10', 'not-a-duration']) {
          final input = manifest([
            content('s0', duration: duration),
            for (var i = 1; i < 5; i++) content('s$i'),
            segment('https://other.host/v/clip.ts'),
          ]);
          final result = purifyM3u8Playlist(
            text: input,
            playlistUri: playlistUri,
          );
          expect(result.abandoned, isTrue, reason: duration);
          expect(result.text, input);
          expect(result.removedSegments, 0);
          expect(result.removedDurationSec, 0);
          expect(result.removed, isEmpty);
        }
      },
    );

    test('unknown non-EXT content tags are not discarded incidentally', () {
      final input = manifest([
        for (var i = 0; i < 5; i++) content('s$i'),
        segment(
          'https://other.host/v/clip.ts',
          tags: ['#CONTENT-ID:program-123'],
        ),
      ]);
      final result = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
      expect(result.abandoned, isTrue);
      expect(result.text, input);
      expect(result.removed, isEmpty);
    });
  });

  test(
    'all low-latency tag forms abort including bare PART/SKIP/PRELOAD-HINT',
    () {
      for (final tag in [
        '#EXT-X-PART',
        '#EXT-X-SKIP',
        '#EXT-X-PRELOAD-HINT',
        '#EXT-X-SKIP:SKIPPED-SEGMENTS=1',
        '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="p.ts"',
      ]) {
        final input = manifest([
          content('s0', tags: [tag]),
          content('s1'),
        ]);
        final r = purifyM3u8Playlist(text: input, playlistUri: playlistUri);
        expect(r.abandoned, isTrue, reason: tag);
        expect(r.text, input);
        expect(r.removedSegments, 0);
        expect(r.removed, isEmpty);
      }
    },
  );

  test('各级命中数能压成一行日志（按次数降序，同级按名字）', () {
    expect(purifyLevelsSummary(const {}), '');
    expect(
      purifyLevelsSummary(const {
        kPurifyLevelDiscontinuityGroups: 2,
        kPurifyLevelMinorityUrl: 11,
      }),
      '$kPurifyLevelMinorityUrl=11,$kPurifyLevelDiscontinuityGroups=2',
    );
  });
}
