import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_preload.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segments.dart';

void main() {
  const duration = 1200000;
  final plan = SkipPlan.empty.withManualOverride(
    manual: const SkipSegments(outroStartMs: 1140000),
    durationMs: duration,
  );

  String? batch(
    int position, {
    int length = duration,
    int? buffered,
    double rate = 1,
    SkipMode mode = SkipMode.auto,
    bool early = false,
    bool ending = false,
    Set<String> handled = const {},
    bool preparingForSeek = false,
  }) => episodePreloadBatch(
    positionMs: position,
    durationMs: length,
    bufferedMs: buffered ?? length,
    rate: rate,
    plan: plan,
    mode: mode,
    kinds: SkipKind.outro.bit,
    handled: handled,
    earlyStarted: early,
    endingStarted: ending,
    preparingForSeek: preparingForSeek,
  )?.name;

  test('long episode warms 25 wall seconds before eligible outro', () {
    expect(batch(1089999, rate: 2), isNull);
    expect(batch(1090000, rate: 2), 'ending');
    expect(batch(1090000, rate: 2, handled: {'manual|outro'}), isNull);
    expect(batch(1090000, rate: 2, mode: SkipMode.confirm), isNull);
    expect(batch(1150000, rate: 2, mode: SkipMode.confirm), 'ending');
    expect(batch(1090000, rate: 2, buffered: 1091000), isNull);
  });

  test(
    'a start point is only applied when the refetched manifest still fits',
    () {
      bool fits(int start, int prefetched, int actual) => preloadedStartFits(
        startMs: start,
        prefetchedDurationMs: prefetched,
        actualDurationMs: actual,
      );
      expect(fits(40000, 45000, 45000), isTrue);
      expect(fits(40000, 45000, 44000), isTrue);
      expect(fits(40000, 45000, 25000), isFalse);
      expect(fits(25000, 45000, 25000), isFalse);
      expect(fits(0, 45000, 25000), isTrue);
      expect(fits(40000, 0, 45000), isFalse);
      expect(fits(40000, 45000, 0), isFalse);
    },
  );

  test('a tail seek can prepare before new buffer arrives, but not already inside the skip', () {
    expect(batch(1125000, buffered: 15000), isNull);
    expect(batch(1125000, buffered: 15000, preparingForSeek: true), 'ending');
    expect(batch(1110000, buffered: 15000, preparingForSeek: true), isNull);
    expect(batch(1140000, buffered: 15000, preparingForSeek: true), isNull);
    expect(
      batch(1125000, buffered: 15000, preparingForSeek: true, ending: true),
      isNull,
    );
    expect(batch(4000, length: 240000, preparingForSeek: true), isNull);
  });

  test('short episode warms early then allows one near-end refresh', () {
    expect(batch(2999, length: 240000), isNull);
    expect(batch(3000, length: 240000), 'early');
    expect(batch(9000, length: 240000, early: true), isNull);
    expect(batch(215000, length: 240000, early: true), 'ending');
    expect(batch(230000, length: 240000, early: true, ending: true), isNull);
  });

  test(
    'only an automatic enabled intro covering position zero can start ahead',
    () {
      int start({
        int from = 0,
        int end = 32000,
        SkipMode mode = SkipMode.auto,
        int? kinds,
        SkipSegments manual = const SkipSegments(),
      }) => episodePreloadStart(
        durationMs: 180000,
        plan: SkipPlan.resolve(
          [
            RawSkipSegment(
              kind: SkipKind.intro,
              provider: 'fixture',
              startMs: from,
              endMs: end,
            ),
          ],
          durationMs: 180000,
        ).withManualOverride(manual: manual, durationMs: 180000),
        mode: mode,
        kinds: kinds ?? SkipKind.intro.bit,
      );
      expect(start(), 32000);
      expect(start(from: 2000), 0);
      expect(start(mode: SkipMode.confirm), 0);
      expect(start(kinds: SkipKind.outro.bit), 0);
      expect(start(manual: const SkipSegments(introEndMs: 24000)), 24000);
      expect(start(manual: const SkipSegments(introEndMs: 190000)), 0);
    },
  );
}
