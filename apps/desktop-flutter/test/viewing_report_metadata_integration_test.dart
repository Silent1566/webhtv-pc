import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

PlaybackHistory history(
  String source, {
  String id = 'v',
  String title = 'Title',
}) => PlaybackHistory(
  id: 1,
  sourceKey: source,
  siteKey: 's',
  vodId: id,
  vodName: title,
  flag: 'f',
  episodeName: 'e',
  episodeId: 'e',
  positionMs: 1,
  durationMs: 2,
  updatedAt: 3,
);

void main() {
  late Directory temp;
  late AppState state;
  Completer<void>? started;
  Completer<void>? release;
  var mismatch = false;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('viewing-integration');
    mismatch = false;
    started = null;
    release = null;
    final client = MockClient((request) async {
      if (request.url.path == '/A' || request.url.path == '/B') {
        return http.Response(
          jsonEncode({
            'sites': [
              {
                'key': 's',
                'name': 'Fixture',
                'type': 1,
                'api': 'https://fixture.test/detail',
              },
            ],
          }),
          200,
        );
      }
      final id = request.url.queryParameters['ids'];
      if (id != null) {
        if (id.startsWith('slow')) {
          started?.complete();
          await release?.future;
        }
        return http.Response(
          jsonEncode({
            'list': [
              {
                'vod_id': id,
                'vod_name': mismatch
                    ? 'Wrong title'
                    : id == 'v'
                    ? 'Title'
                    : id,
                'vod_actor': 'Actor',
                'vod_director': 'Director',
                'vod_area': 'Japan',
                'type_name': 'Drama',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{"list":[]}', 200);
    });
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    state = AppState(paths: paths, log: LogService(), httpClient: client);
    final config = jsonEncode({
      'sites': [
        {
          'key': 's',
          'name': 'Fixture',
          'type': 1,
          'api': 'https://fixture.test/detail',
        },
      ],
    });
    File('${temp.path}/A.json').writeAsStringSync(config);
    File('${temp.path}/B.json').writeAsStringSync(config);
    await state.bootstrap();
    expect(await state.importConfig('${temp.path}/A.json'), isTrue);
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'actual detail capture provides metadata without creating history',
    () async {
      final source = state.activeSourceKey;
      await state.loadDetail(Vod(vodId: 'v', vodName: 'Title'));
      expect(state.viewingReportMetadata([history(source)])[1]?.actors, [
        'Actor',
      ]);
      expect(state.database!.historyCount(), 0);
      expect(state.database!.count('viewing_metadata'), 1);
    },
  );

  test('outdated detail cannot collect and latest result can', () async {
    final source = state.activeSourceKey;
    started = Completer<void>();
    release = Completer<void>();
    final slow = state.loadDetail(Vod(vodId: 'slow', vodName: 'slow'));
    await started!.future;
    await state.loadDetail(Vod(vodId: 'v', vodName: 'Title'));
    release!.complete();
    await slow;
    expect(
      state.viewingReportMetadata([history(source, id: 'slow', title: 'slow')]),
      isEmpty,
    );
    expect(state.viewingReportMetadata([history(source)])[1]?.genres, [
      'Drama',
    ]);
    expect(state.database!.count('viewing_metadata'), 1);
  });

  test('incognito at request start or completion never captures', () async {
    final source = state.activeSourceKey;
    await state.setIncognito(true);
    started = Completer<void>();
    release = Completer<void>();
    final slow = state.loadDetail(Vod(vodId: 'slow', vodName: 'slow'));
    await started!.future;
    await state.setIncognito(false);
    release!.complete();
    await slow;
    expect(state.database!.count('viewing_metadata'), 0);
    started = Completer<void>();
    release = Completer<void>();
    final pending = state.loadDetail(Vod(vodId: 'slow2', vodName: 'slow2'));
    await started!.future;
    await state.setIncognito(true);
    release!.complete();
    await pending;
    state.recordProgress(
      vod: Vod(vodId: 'v', vodName: 'Title', vodActor: 'Private'),
      flag: 'f',
      episodeName: 'e',
      episodeId: 'e',
      position: Duration.zero,
      duration: const Duration(seconds: 1),
    );
    expect(state.database!.count('viewing_metadata'), 0);
    expect(state.database!.historyCount(), 0);
    expect(state.viewingReportMetadata([history(source)]), isEmpty);
  });

  test('source switch discards in-flight capture; original source override stays isolated', () async {
    final sourceA = state.activeSourceKey;
    final contextA = state.playbackContextFor(sourceA)!;
    started = Completer<void>();
    release = Completer<void>();
    final pending = state.loadDetail(Vod(vodId: 'slow', vodName: 'slow'));
    await started!.future;
    expect(await state.importConfig('${temp.path}/B.json'), isTrue);
    final sourceB = state.activeSourceKey;
    expect(sourceB, isNot(sourceA));
    release!.complete();
    await pending;
    expect(state.database!.count('viewing_metadata'), 0);
    await state.loadDetail(
      Vod(vodId: 'v', vodName: 'Title'),
      serviceOverride: contextA.service,
      siteOverride: contextA.siteByKey('s'),
    );
    expect(state.viewingReportMetadata([history(sourceA)])[1]?.areas, [
      'Japan',
    ]);
    expect(state.viewingReportMetadata([history(sourceB)]), isEmpty);
  });

  test(
    'wrong-title detail is not attached to requested history identity',
    () async {
      final source = state.activeSourceKey;
      mismatch = true;
      await state.loadDetail(Vod(vodId: 'v', vodName: 'Title'));
      expect(state.viewingReportMetadata([history(source)]), isEmpty);
      expect(state.database!.count('viewing_metadata'), 0);
    },
  );

  test('progress with known Vod fills snapshot and later empty progress preserves it', () {
    final source = state.activeSourceKey;
    void progress(Vod vod) => state.recordProgress(
      vod: vod,
      flag: 'f',
      episodeName: 'e',
      episodeId: 'e',
      position: const Duration(seconds: 2),
      duration: const Duration(seconds: 5),
    );
    progress(Vod(vodId: 'v', vodName: 'Title', vodActor: 'Known'));
    progress(Vod(vodId: 'v', vodName: 'Title'));
    expect(state.viewingReportMetadata([history(source)])[1]?.actors, [
      'Known',
    ]);
    expect(state.database!.historyCount(), 1);
  });
}
