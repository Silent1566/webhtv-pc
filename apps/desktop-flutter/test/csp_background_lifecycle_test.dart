import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/detail_test_seams.dart';

class _State extends AppState {
  _State(AppPaths paths)
    : super(
        paths: paths,
        log: MemoryOnlyLogService(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

  AppConfig? probeConfig;

  @override
  AppConfig? get effectiveConfig => probeConfig ?? super.effectiveConfig;

  @override
  Future<void> loadHome(Site site) async {}
}

class _ObservedSites extends ListBase<Site> {
  _ObservedSites(this.site);
  final Site site;
  int reads = 0;

  @override
  int get length {
    reads++;
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('read-only');

  @override
  Site operator [](int index) => site;

  @override
  void operator []=(int index, Site value) =>
      throw UnsupportedError('read-only');
}

class _ScheduledTimers {
  final timers = <Timer>[];

  T capture<T>(T Function() action) => runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createTimer(zone, duration, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

void main() {
  late Directory temp;
  late _State state;
  var disposed = false;

  void disposeState() {
    state.dispose();
    disposed = true;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('background-lifecycle-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    paths.ensureDirectories();
    state = _State(paths);
    disposed = false;
  });

  tearDown(() async {
    if (!disposed) disposeState();
    await temp.delete(recursive: true);
  });

  for (final api in <String>[
    'https://fixture.invalid/station',
    'spider-local:fixture',
    'web-home:fixture',
  ]) {
    testWidgets('automatic attachment has no background work for $api', (
      tester,
    ) async {
      expect(
        await state.importConfig(
          jsonEncode({
            'sites': [
              {'key': 'fixture', 'name': 'fixture', 'type': 4, 'api': api},
            ],
          }),
        ),
        isTrue,
        reason: state.lastError?.toString(),
      );
      expect(state.cspProvisionProgress.active, isFalse);
      expect(state.cspProvisionSummary, isNull);
      expect(state.debugProvisioningSiteKeys, isEmpty);
      expect(state.debugDirectSpiders, isEmpty);
    });
  }

  test(
    'public provisioning does not read sites before the first event yield',
    () async {
      final sites = _ObservedSites(
        Site(key: 'csp', name: 'csp', type: 3, api: 'csp_Demo'),
      );
      final config = AppConfig(
        spider: 'https://fixture.invalid/shared.jar',
        sites: sites,
      );
      state.probeConfig = config;
      state.debugCspProvisionOverride = (config, {onProgress, onEntry}) async =>
          const CspProbeReport();
      final scheduled = _ScheduledTimers();
      final pending = scheduled.capture(
        () => state.provisionCspJarsQuietly(config),
      );
      expect(sites.reads, 0);
      expect(state.cspProvisionProgress.active, isTrue);
      await Future<void>.value();
      expect(sites.reads, 0, reason: 'microtasks must not perform the scan');
      expect(scheduled.timers, hasLength(1));
      await pending;
      expect(sites.reads, greaterThan(0));
      expect(state.cspProvisionProgress.active, isFalse);
    },
  );

  testWidgets('dispose cancels the CSP event yield and settles its future', (
    tester,
  ) async {
    final sites = _ObservedSites(
      Site(key: 'csp', name: 'csp', type: 3, api: 'csp_Demo'),
    );
    final config = AppConfig(
      spider: 'https://fixture.invalid/shared.jar',
      sites: sites,
    );
    state.probeConfig = config;
    final scheduled = _ScheduledTimers();
    var notifications = 0;
    state.addListener(() => notifications++);
    final pending = scheduled.capture(
      () => state.provisionCspJarsQuietly(config),
    );
    expect(scheduled.timers, hasLength(1));
    expect(sites.reads, 0);
    final beforeDispose = notifications;
    disposeState();
    expect(scheduled.timers.single.isActive, isFalse);
    await pending;
    expect(sites.reads, 0);
    expect(notifications, beforeDispose);
  });

  testWidgets('dispose cancels direct registration before materialization', (
    tester,
  ) async {
    final config = AppConfig(
      sites: [
        Site(
          key: 'direct',
          name: 'direct',
          type: 3,
          api: 'https://fixture.invalid/direct.js',
        ),
      ],
    );
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
    );
    addTearDown(router.dispose);
    var materialized = false;
    state.debugDirectProbeOverride = (config) async {
      materialized = true;
      return {};
    };
    final scheduled = _ScheduledTimers();
    final pending = scheduled.capture(
      () => state.debugRegisterDirectSpidersFor(config, router),
    );
    expect(scheduled.timers, hasLength(1));
    expect(materialized, isFalse);
    disposeState();
    expect(scheduled.timers.single.isActive, isFalse);
    await pending;
    expect(materialized, isFalse);
    expect(router.directSpiders, isEmpty);
  });

  test(
    'switching to no-work config clears old provisioning context and keys',
    () async {
      final oldConfig = AppConfig(
        spider: 'https://fixture.invalid/shared.jar',
        sites: [Site(key: 'old', name: 'old', type: 3, api: 'csp_Demo')],
      );
      state.probeConfig = oldConfig;
      final result = Completer<CspProbeReport>();
      state.debugCspProvisionOverride = (config, {onProgress, onEntry}) =>
          result.future;
      final pending = state.provisionCspJarsQuietly(oldConfig);
      await Future<void>.delayed(Duration.zero);
      expect(state.debugProvisioningSiteKeys, {'old'});
      state.probeConfig = null;
      expect(
        await state.importConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'http',
                'name': 'http',
                'type': 4,
                'api': 'https://fixture.invalid/station',
              },
            ],
          }),
        ),
        isTrue,
      );
      expect(state.cspProvisionProgress.active, isFalse);
      expect(state.cspProvisionSummary, isNull);
      expect(state.debugProvisioningSiteKeys, isEmpty);
      result.complete(const CspProbeReport());
      await pending;
      expect(state.cspProvisionProgress.active, isFalse);
      expect(state.cspProvisionSummary, isNull);
      expect(state.debugProvisioningSiteKeys, isEmpty);
    },
  );

  testWidgets('rejected empty config does not schedule background work', (
    tester,
  ) async {
    expect(await state.importConfig(jsonEncode({'sites': []})), isFalse);
    expect(state.config, isNull);
    expect(state.cspProvisionProgress.active, isFalse);
    expect(state.debugProvisioningSiteKeys, isEmpty);
  });

  test('removing the active config clears old provisioning keys', () async {
    await state.bootstrap();
    final result = Completer<CspProbeReport>();
    state.debugCspProvisionOverride = (config, {onProgress, onEntry}) =>
        result.future;
    expect(
      await state.importConfig(
        jsonEncode({
          'spider': 'https://fixture.invalid/shared.jar',
          'sites': [
            {'key': 'old', 'name': 'old', 'type': 3, 'api': 'csp_Demo'},
          ],
        }),
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.debugProvisioningSiteKeys, {'old'});
    await state.deleteConfigRecord(state.activeRecord!.id);
    expect(state.effectiveConfig, isNull);
    expect(state.debugProvisioningSiteKeys, isEmpty);
    result.complete(const CspProbeReport());
    await Future<void>.delayed(Duration.zero);
    expect(state.debugProvisioningSiteKeys, isEmpty);
  });
  test(
    'removing the last config retains only local HTML in effective config',
    () async {
      await state.bootstrap();
      final result = Completer<CspProbeReport>();
      state.debugCspProvisionOverride = (config, {onProgress, onEntry}) =>
          result.future;
      expect(
        await state.importConfig(
          jsonEncode({
            'spider': 'https://fixture.invalid/shared.jar',
            'sites': [
              {'key': 'old', 'name': 'old', 'type': 3, 'api': 'csp_Demo'},
            ],
          }),
        ),
        isTrue,
      );
      final online = await state.addOnlineWebHome(
        'https://fixture.invalid/local-home',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        state.effectiveConfig!.sites.map((site) => site.key),
        contains('old'),
      );
      await state.deleteConfigRecord(state.activeRecord!.id);
      expect(state.effectiveConfig!.sites.map((site) => site.key), [
        online.key,
      ]);
      expect(state.cspProvisionProgress.active, isFalse);
      expect(state.debugProvisioningSiteKeys, isEmpty);
      result.complete(const CspProbeReport());
      await Future<void>.delayed(Duration.zero);
      expect(state.debugProvisioningSiteKeys, isEmpty);
    },
  );
}
