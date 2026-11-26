import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/services/intro_skip/todb_provider.dart';

RawSkipSegment marker(
  String version,
  SkipKind kind,
  int start,
  int end,
  int runtime,
) => RawSkipSegment(
  kind: kind,
  provider: 'todb',
  versionId: version,
  identity: 'todb|$version|${kind.name}|$start',
  startMs: start,
  endMs: end,
  referenceDurationMs: runtime,
);

void main() {
  test('unknown candidate runtime prevents a falsely unique version match', () {
    final plan = SkipPlan.resolve([
      marker('A', SkipKind.intro, 0, 10000, 100000),
      marker('B', SkipKind.intro, 0, 20000, 0),
    ], durationMs: 100000);
    expect(plan.segments, isEmpty);
  });

  test(
    'version without valid markers cannot defeat a usable nearby version',
    () {
      final plan = SkipPlan.resolve([
        marker('A', SkipKind.intro, 50000, 10000, 100000),
        marker('B', SkipKind.intro, 0, 20000, 101000),
      ], durationMs: 100000);
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.identity, startsWith('todb|B|'));
    },
  );

  test('inconsistent references inside a viable version are ambiguous', () {
    final plan = SkipPlan.resolve([
      marker('A', SkipKind.intro, 0, 10000, 100000),
      marker('A', SkipKind.outro, 80000, 100000, 110000),
      marker('B', SkipKind.intro, 0, 20000, 101000),
    ], durationMs: 100000);
    expect(plan.segments, isEmpty);
  });

  test('one version with unknown runtime still keeps its valid intro', () {
    final plan = SkipPlan.resolve([
      marker('A', SkipKind.intro, 0, 10000, 0),
    ], durationMs: 100000);
    expect(plan.segments, hasLength(1));
  });

  test('distinct ending types stay available even at the same timestamp', () {
    final plan = SkipPlan.resolve(const [
      RawSkipSegment(
        kind: SkipKind.outro,
        provider: 'a',
        identity: 'outro',
        startMs: 90000,
        endMs: 100000,
        referenceDurationMs: 100000,
      ),
      RawSkipSegment(
        kind: SkipKind.postCredits,
        provider: 'b',
        identity: 'post',
        startMs: 90000,
        endMs: 100000,
        referenceDurationMs: 100000,
      ),
      RawSkipSegment(
        kind: SkipKind.preview,
        provider: 'c',
        identity: 'preview',
        startMs: 90000,
        endMs: 100000,
        referenceDurationMs: 100000,
      ),
    ], durationMs: 100000);
    expect(plan.endings.map((s) => s.kind).toSet(), {
      SkipKind.outro,
      SkipKind.postCredits,
      SkipKind.preview,
    });
  });

  test('provider retains explicit playback version identity', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'items': [
            {
              'version_id': 1,
              'version_runtime': 100,
              'marker': [
                {
                  'marker_id': 11,
                  'marker_type': 'intro',
                  'time_start': 0,
                  'time_end': 10,
                },
              ],
            },
            {
              'version_id': 2,
              'version_runtime': 110,
              'marker': [
                {
                  'marker_id': 21,
                  'marker_type': 'credits',
                  'time_start': 90,
                  'time_end': 110,
                },
              ],
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);
    final raw = await const TodbProvider().fetch(
      const SkipQuery(tmdbId: 1, season: 1, episode: 1),
      client: client,
    );
    expect(raw!.map((s) => s.versionId), ['1', '2']);
  });

  test('closest runtime selects a coherent intro, midroll and outro group', () {
    final raw = [
      marker('A', SkipKind.intro, 0, 10000, 100000),
      marker('A', SkipKind.advertisement, 30000, 40000, 100000),
      marker('A', SkipKind.outro, 90000, 100000, 100000),
      marker('B', SkipKind.intro, 0, 20000, 120000),
      marker('B', SkipKind.advertisement, 50000, 60000, 120000),
      marker('B', SkipKind.outro, 105000, 120000, 120000),
    ];
    for (final order in [raw, raw.reversed.toList()]) {
      final plan = SkipPlan.resolve(order, durationMs: 119000);
      expect(plan.segments, hasLength(3));
      expect(
        plan.segments.every((s) => s.identity.startsWith('todb|B|')),
        isTrue,
      );
    }
    final refined = SkipPlan.resolve(raw, durationMs: 100100);
    expect(
      refined.segments.every((s) => s.identity.startsWith('todb|A|')),
      isTrue,
    );
  });

  test(
    'unknown or equally close variants do not mix incompatible timelines',
    () {
      final raw = [
        marker('A', SkipKind.intro, 0, 10000, 100000),
        marker('B', SkipKind.intro, 0, 20000, 120000),
      ];
      expect(SkipPlan.resolve(raw, durationMs: 0).segments, isEmpty);
      expect(SkipPlan.resolve(raw, durationMs: 110000).segments, isEmpty);
    },
  );

  test('unversioned segments are not silently removed by different reference durations', () {
    const raw = [
      RawSkipSegment(
        kind: SkipKind.advertisement,
        provider: 'other',
        identity: 'ad-a',
        startMs: 30000,
        endMs: 35000,
        referenceDurationMs: 100000,
      ),
      RawSkipSegment(
        kind: SkipKind.intermission,
        provider: 'other',
        identity: 'break-b',
        startMs: 50000,
        endMs: 55000,
        referenceDurationMs: 105000,
      ),
    ];
    expect(SkipPlan.resolve(raw, durationMs: 100000).segments, hasLength(2));
  });

  test(
    'later open-ended outro wins independent of scores and response order',
    () {
      const early = RawSkipSegment(
        kind: SkipKind.outro,
        provider: 'a',
        identity: 'early',
        startMs: 70000,
        endMs: 100000,
        confidence: 1,
        submissionCount: 20,
        referenceDurationMs: 100000,
      );
      const late = RawSkipSegment(
        kind: SkipKind.outro,
        provider: 'b',
        identity: 'late',
        startMs: 90000,
        endMs: 100000,
        confidence: 0.1,
        referenceDurationMs: 100000,
      );
      for (final raw in [
        const [early, late],
        const [late, early],
      ]) {
        final plan = SkipPlan.resolve(raw, durationMs: 100000);
        expect(plan.endings, hasLength(1));
        expect(plan.endings.single.startMs, 90000);
      }
    },
  );
}
