import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_rules.dart';

void main() {
  final playlist = Uri.parse('https://cdn.good/main.m3u8');
  const ads = AdRuleSet(adHosts: ['ads.example']);
  String manifest({bool live = false, String sequence = '10'}) =>
      '''
#EXTM3U
#EXT-X-TARGETDURATION:1
#EXT-X-MEDIA-SEQUENCE:$sequence
#EXTINF:1,
https://ads.example/ad.ts
#EXTINF:1,
https://cdn.good/1.ts
#EXTINF:1,
https://cdn.good/2.ts
${live ? '' : '#EXT-X-ENDLIST'}
''';
  HlsCleanResult clean(String text, [AdRuleSet rules = ads]) =>
      cleanHlsPlaylist(text: text, playlistUri: playlist, rules: rules);
  Map<String, Object?> rule([Map<String, Object?> extra = const {}]) => {
    'id': 'rule',
    'playlistHostSuffixes': ['cdn.good'],
    'hostSuffixes': ['ads.example'],
    ...extra,
  };

  test('32 regex expressions are accepted, 33 are rejected as one rule', () {
    final patterns = [for (var i = 0; i < 33; i++) '/ad$i'];
    expect(
      HlsAdRule.listFrom([
        rule({'segmentUrlRegex': patterns.take(32).toList()}),
      ]),
      hasLength(1),
    );
    expect(
      HlsAdRule.listFrom([
        rule({'segmentUrlRegex': patterns}),
      ]),
      isEmpty,
    );
  });

  test('nonfinite and fractional signal thresholds cannot weaken a rule', () {
    for (final threshold in [double.nan, double.infinity, 1.5]) {
      expect(
        HlsAdRule.listFrom([
          rule({'minimumSignals': threshold}),
        ]),
        isEmpty,
        reason: 'invalid minimumSignals must reject the entire rule',
      );
    }
  });

  test('invalid or incomplete duration bounds reject the entire rule', () {
    for (final range in <Map<String, Object?>>[
      {'minDuration': double.nan, 'maxDuration': 2},
      {'minDuration': 1, 'maxDuration': double.infinity},
      {'minDuration': 2, 'maxDuration': 1},
      {'minDuration': -1, 'maxDuration': 1},
      {'minDuration': 1},
    ]) {
      expect(HlsAdRule.listFrom([rule(range)]), isEmpty, reason: '$range');
    }
  });

  test('invalid exclude regex cannot silently remove protected content', () {
    const rules = AdRuleSet(
      hlsRules: [
        HlsAdRule(
          id: 'invalid',
          playlistHostSuffixes: ['cdn.good'],
          hostSuffixes: ['ads.example'],
          excludeUrlRegex: ['['],
        ),
      ],
    );
    final text = manifest();
    expect(clean(text, rules).text, text);
  });

  test(
    'segment regex remains case-sensitive as the existing contract requires',
    () {
      const rules = AdRuleSet(
        hlsRules: [
          HlsAdRule(
            id: 'case',
            playlistHostSuffixes: ['cdn.good'],
            segmentUrlRegex: [r'/AD\.ts'],
          ),
        ],
      );
      final text = manifest();
      expect(clean(text, rules).text, text);
    },
  );

  test('invalid media durations cannot bypass the removal-duration cap', () {
    for (final value in ['NaN', 'Infinity', '-1', 'not-a-duration']) {
      final text = manifest().replaceFirst('#EXTINF:1,', '#EXTINF:$value,');
      final result = clean(text);
      expect(result.text, text, reason: value);
      expect(result.changed, isFalse, reason: value);
      expect(result.abandoned, isTrue, reason: value);
    }
  });

  test('live duplicate EXTINF is malformed and must not be rewritten', () {
    final text = manifest(live: true)
        .replaceFirst('#EXTINF:1,', '#EXTINF:1,\n#EXTINF:1,');
    expect(clean(text).text, text);
    expect(clean(text).abandoned, isTrue);
  });

  test('live URI without EXTINF is not treated as a removable segment', () {
    const text = '''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:10
https://ads.example/ad.ts
https://cdn.good/1.ts
https://cdn.good/2.ts
''';
    expect(clean(text).text, text);
    expect(clean(text).abandoned, isTrue);
  });

  test(
    'unsigned 64-bit live media sequence is advanced without truncation',
    () {
      final text = manifest(live: true, sequence: '18446744073709551614');
      final result = clean(text);
      expect(result.removedSegments, 1);
      expect(
        result.text,
        contains('#EXT-X-MEDIA-SEQUENCE:18446744073709551615'),
      );
    },
  );

  test('live sequence overflow leaves the original playlist untouched', () {
    final text = manifest(live: true, sequence: '18446744073709551615');
    expect(clean(text).text, text);
    expect(clean(text).abandoned, isTrue);
  });
}
