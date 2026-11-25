@Tags(['external'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/node_runtime.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';
import 'spider_proxy_session_test.dart' show proxySessionFixtureSource;

void main() {
  final node = NodeRuntimeResolver.resolve();
  if (node == null) {
    test(
      'player proxy lifecycle requires Node',
      () {},
      skip: 'Node runtime unavailable',
    );
    return;
  }
  WidgetTester? currentTester;
  late Directory temp;
  late AppState app;
  late SpiderHostSupervisor supervisor;
  late SidecarRuntime runtime;
  late SiteService service;
  late _RuntimeRouter router;
  setUp(() async {
    currentTester = null;
    temp = await Directory.systemTemp.createTemp('player-proxy-lifecycle-');
    final log = LogService();
    app = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'state'),
        },
      ),
      log: log,
    );
    supervisor = SpiderHostSupervisor(
      workRoot: p.join(temp.path, 'work'),
      log: log,
      idleTimeout: const Duration(seconds: 2),
    );
    final script = File(p.join(temp.path, 'host.cjs'));
    await script.writeAsString(proxySessionFixtureSource);
    final site = Site(
      key: 'fixture',
      name: 'fixture',
      type: 3,
      api: 'csp_Fixture',
    );
    final manifest = SpiderManifest(
      key: 'fixture',
      name: 'fixture',
      runtime: 'jvm',
      entry: 'host.cjs',
      capabilities: const [
        'home',
        'category',
        'detail',
        'search',
        'play',
        'proxy',
      ],
      permissions: const SpiderPermissions(localProxy: true),
    );
    runtime = SidecarRuntime(
      site: site,
      spider: LocalSpider(
        manifest: manifest,
        manifestPath: p.join(temp.path, 'manifest.json'),
        rootDir: temp.path,
        entryPath: script.path,
      ),
      command: LocalSpiderCommand(
        executable: node.executable,
        arguments: [...node.arguments, script.path],
      ),
      supervisor: supervisor,
    );
    router = _RuntimeRouter(runtime);
    service = SiteService(
      appConfig: AppConfig(sites: [site]),
      router: router,
    );
  });
  tearDown(() async {
    await currentTester!.runAsync(() async {
      app.dispose();
      router.dispose();
      await supervisor.shutdownAll();
      await temp.delete(recursive: true);
    });
  });

  Future<PlaybackDecision> resolve(WidgetTester tester) async =>
      (await tester.runAsync(
        () async => (await app.resolvePlayback(
          siteOverride: runtime.site,
          serviceOverride: service,
          episodeTarget: 'opaque',
        ))!,
      ))!;
  Future<int> status(WidgetTester tester, String url) async =>
      (await tester.runAsync(() async {
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealNetwork(),
        );
        try {
          final response = await (await client.getUrl(Uri.parse(url))).close();
          await response.drain<void>();
          return response.statusCode;
        } finally {
          client.close(force: true);
        }
      }))!;
  Future<void> mount(
    WidgetTester tester,
    String url, {
    bool pushRoute = false,
  }) async {
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final page = PlayerPage(
      state: app,
      request: PlaybackRequest(
        url: url,
        title: 'fixture',
        siteKey: 'fixture',
        vodId: '',
        vodName: 'fixture',
        episodeName: 'one',
        flag: 'fixture',
        directUrl: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: pushRoute
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => page)),
                    child: const Text('open'),
                  ),
                ),
              )
            : page,
      ),
    );
    if (pushRoute) {
      await tester.tap(find.text('open'));
    }
    await settlePlayerPage(tester, times: 2);
  }

  testWidgets(
    'route pop releases JVM token and lease, then normal idle reclaims host',
    (tester) async {
      currentTester = tester;
      final decision = await resolve(tester);
      final host = supervisor.hostFor('fixture')!;
      expect(await status(tester, decision.url!), 200);
      await mount(tester, decision.url!, pushRoute: true);
      expect(host.activePlaybackLeaseCount, 1);
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(PlayerPage), findsNothing);
      expect(host.activePlaybackLeaseCount, 0);
      expect(await status(tester, decision.url!), 403);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2300)),
      );
      expect(supervisor.hostFor('fixture'), isNull);
    },
  );
  testWidgets(
    'widget dispose releases JVM owner even for a public returned media URL',
    (tester) async {
      currentTester = tester;
      final script = File(p.join(temp.path, 'host.cjs'));
      await tester.runAsync(
        () => script.writeAsString(
          proxySessionFixtureSource.replaceFirst(
            "'http://127.0.0.1:'+server.address().port+'/s/'+session.token+'/proxy?action=media'",
            "'https://public.invalid/fixture.mp4'",
          ),
        ),
      );
      final decision = await resolve(tester);
      expect(decision.url, 'https://public.invalid/fixture.mp4');
      final host = supervisor.hostFor('fixture')!;
      await mount(tester, decision.url!);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(host.activePlaybackLeaseCount, 0);
      await tester.runAsync(supervisor.shutdownAll);
    },
  );
  testWidgets('old page dispose cannot revoke replacement playback owner', (
    tester,
  ) async {
    currentTester = tester;
    final old = await resolve(tester);
    await mount(tester, old.url!);
    final next = await resolve(tester);
    final host = supervisor.hostFor('fixture')!;
    expect(await status(tester, next.url!), 200);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(host.activePlaybackLeaseCount, 1);
    expect(await status(tester, next.url!), 200);
    await tester.runAsync(() async {
      app.revokeProxySession();
      await supervisor.shutdownAll();
    });
  });
}

class _RuntimeRouter extends SpiderRouter {
  _RuntimeRouter(this.runtime)
    : super(client: HttpApiClient(), globalHeaders: const []);
  final SidecarRuntime runtime;
  @override
  SiteRuntime runtimeFor(Site site) => runtime;
}

class _RealNetwork extends HttpOverrides {}
