import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/detail_load_trace.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'support/detail_test_seams.dart';

FrameTiming frame(int vsync, {int build = 1000, int raster = 1000}) =>
    FrameTiming(
      vsyncStart: vsync,
      buildStart: vsync,
      buildFinish: vsync + build,
      rasterStart: vsync + build,
      rasterFinish: vsync + build + raster,
      rasterFinishWallTime: 0,
      frameNumber: vsync,
    );

void main() {
  testWidgets('page logs its usable frame once after source detail arrives', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final log = MemoryOnlyLogService();
    final state = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('webhtv-detail-trace');
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            for (final key in ['config', 'data', 'cache', 'state'])
              key: '${temp.path}/$key',
          },
        ),
        log: log,
        httpClient: MockClient(
          (request) async => request.url.queryParameters.containsKey('ids')
              ? response.future
              : http.Response('{"class":[],"list":[]}', 200),
        ),
      );
      addTearDown(() async {
        state.dispose();
        await temp.delete(recursive: true);
      });
      await bootstrapWithoutExternalMeta(state);
      expect(
        await state.importConfig('''
        {"sites":[{"key":"fixture","name":"Fixture","type":1,"api":"http://fixture.invalid/vod"}]}
        '''),
        isTrue,
      );
      return state;
    }))!;
    Iterable<String> messages() => log.entries
        .where((entry) => entry.scope == 'detail-perf')
        .map((entry) => entry.message);
    Iterable<String> firstFrames() => messages().where(
      (message) => message.contains('stage=first_detail_frame '),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'detail', vodName: 'Fixture detail'),
        ),
      ),
    );
    await tester.pump();
    expect(state.detailPhase, LoadPhase.loading);
    expect(firstFrames(), isEmpty);

    response.complete(
      http.Response(
        jsonEncode({
          'list': [
            {
              'vod_id': 'detail',
              'vod_name': 'Fixture detail',
              'vod_play_from': 'fixture-line',
              'vod_play_url': r'Episode 1$http://fixture.invalid/video.mp4',
            },
          ],
        }),
        200,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    expect(firstFrames(), hasLength(1));
    final run = RegExp(r'run=[0-9]+')
        .firstMatch(firstFrames().single)!
        .group(0);
    expect(firstFrames().single, contains('playableLines=1'));
    expect(
      messages(),
      containsAllInOrder([
        startsWith('$run stage=detail_ready '),
        startsWith('$run stage=first_detail_frame '),
      ]),
    );
    await tester.pump();
    expect(firstFrames(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'stages share a run and use monotonic elapsed and delta milliseconds',
    () {
      final log = MemoryOnlyLogService();
      var elapsed = Duration.zero;
      final trace = DetailLoadTrace(log: log, runId: 7, elapsed: () => elapsed);
      elapsed = const Duration(milliseconds: 80);
      trace.mark('runtime_ready');
      elapsed = const Duration(milliseconds: 230);
      trace.mark('source_return');
      trace.mark('source_return');
      expect(log.entries.map((e) => e.scope), everyElement('detail-perf'));
      expect(log.entries.map((e) => e.message), [
        'run=7 stage=start elapsedMs=0 deltaMs=0',
        'run=7 stage=runtime_ready elapsedMs=80 deltaMs=80',
        'run=7 stage=source_return elapsedMs=230 deltaMs=150',
      ]);
    },
  );

  test('batched timings exclude frames outside the detail loading window', () {
    final log = MemoryOnlyLogService();
    final trace = DetailLoadTrace(log: log, runId: 3);
    trace.beginFrames(100000);
    trace.endFrames(300000, 'first_detail_frame');
    trace.recordFrames([
      frame(50000, build: 900000),
      frame(100000, build: 20000, raster: 2000),
      frame(200000, build: 1000, raster: 60000),
      frame(300000),
      frame(400000, build: 800000),
    ]);
    expect(trace.framesFinished, isTrue);
    final summary = log.entries.last.message;
    expect(summary, contains('run=3 stage=frames'));
    expect(summary, contains('samples=3'));
    expect(summary, contains('slowFrames=2'));
    expect(summary, contains('longFrames=1'));
    expect(summary, contains('maxBuildMs=20.0'));
    expect(summary, contains('maxRasterMs=60.0'));
    expect(summary, contains('timingStatus=complete'));
    final count = log.entries.length;
    trace.recordFrames([frame(300000)]);
    trace.finishFrames('disposed');
    expect(log.entries, hasLength(count));
  });

  test('disposing without engine samples does not report a smooth load', () {
    final log = MemoryOnlyLogService();
    final trace = DetailLoadTrace(log: log, runId: 4);
    trace.beginFrames(100000);
    trace.endFrames(200000, 'first_detail_frame');
    trace.finishFrames('disposed');
    expect(log.entries.last.message, contains('samples=0'));
    expect(log.entries.last.message, contains('timingStatus=unavailable'));
    expect(log.entries.last.message, contains('reason=disposed'));
  });
}
