import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import '../integration_test/support/mvp_fixture_environment.dart';

class _RealHttpOverrides extends HttpOverrides {}

final class _BoundaryFiles extends IOOverrides {
  final file = _BoundaryFile();

  @override
  File createFile(String path) =>
      path.endsWith('usage-boundary-accepted') ? file : super.createFile(path);
}

class _BoundaryFile implements File {
  Completer<bool>? existsGate;
  Completer<File>? writeGate;
  int writeCalls = 0;

  @override
  Future<bool> exists() => existsGate?.future ?? Future.value(false);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    writeCalls++;
    return writeGate?.future ?? Future.value(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _withBoundaryFiles(Future<void> Function(_BoundaryFiles) body) {
  final files = _BoundaryFiles();
  return IOOverrides.runWithIOOverrides(() => body(files), files);
}

class _StateListener extends StatefulWidget {
  const _StateListener(this.environment);
  final MvpFixtureEnvironment environment;

  @override
  State<_StateListener> createState() => _StateListenerState();
}

class _StateListenerState extends State<_StateListener> {
  @override
  void initState() {
    super.initState();
    widget.environment.state.addListener(_changed);
  }

  void _changed() {}

  @override
  void dispose() {
    widget.environment.state.removeListener(_changed);
    widget.environment.state.clearNotice();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => switch (call.method) {
        'isFullScreen' || 'isPreventClose' || 'isMaximized' => false,
        'isFocused' => true,
        _ => null,
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });

  test(
    'fixture disables optional external metadata before pages mount',
    () async {
      final environment = await MvpFixtureEnvironment.create();
      addTearDown(environment.dispose);
      expect(environment.state.externalMetaEnabled, isFalse);
      expect(environment.state.externalMetaService.isEnabled, isFalse);
    },
  );

  test('profiles keep configuration, SQLite, cache and logs in distinct temp roots', () async {
    final first = await MvpFixtureEnvironment.create();
    final second = await MvpFixtureEnvironment.create();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    for (final environment in [first, second]) {
      for (final path in [
        environment.paths.configDir,
        environment.paths.dataDir,
        environment.paths.cacheDir,
        environment.paths.logDir,
      ]) {
        expect(path, startsWith('${environment.directory.path}/'));
      }
      expect(environment.state.database, isNotNull);
      expect(File(environment.paths.databasePath).existsSync(), isTrue);
    }
    first.state.recordProgress(
      vod: Vod(vodId: 'fixture-id', vodName: 'Fixture'),
      flag: 'fixture',
      episodeName: 'Episode 1',
      episodeId: 'loopback-episode',
      position: const Duration(seconds: 1),
      duration: const Duration(seconds: 10),
    );
    expect(first.state.recentHistory(), hasLength(1));
    expect(second.state.recentHistory(), isEmpty);
  });

  test(
    'recommendations consume an empty local fixture rather than Douban sockets',
    () async {
      final environment = await MvpFixtureEnvironment.create();
      addTearDown(environment.dispose);
      final dependencies = environment.state.recommendationDependencies;
      final loaders = dependencies.acquire();
      final page = await loaders[RecommendationRow.douban]!(
        const RecommendationRequest(
          current: RecommendationSeed(title: 'Fixture'),
        ),
      );
      dependencies.release();
      expect(page.items, isEmpty);
      expect(environment.metadataRequests, hasLength(1));
      expect(environment.metadataRequests.single.host, 'movie.douban.com');
      expect(environment.metadataRequests.single.path, '/j/subject_suggest');
    },
  );

  test(
    'site requests still traverse real loopback HTTP',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final environment = await MvpFixtureEnvironment.create();
      addTearDown(environment.dispose);
      final hits = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        hits.add(request.uri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'class': [
              {'type_id': '1', 'type_name': 'Fixture'},
            ],
            'list': [
              {'vod_id': 'fixture-id', 'vod_name': 'Fixture title'},
            ],
          }),
        );
        await request.response.close();
      });
      final imported = await environment.state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'loopback',
              'name': 'Loopback',
              'type': 1,
              'searchable': 1,
              'api': 'http://127.0.0.1:${server.port}/api/',
            },
          ],
        }),
      );
      expect(imported, isTrue);
      final site = environment.state.siteItems.single.site;
      final result = await environment.state.search(
        site,
        keyword: 'Fixture title',
      );
      expect(result!.list.single.vodName, 'Fixture title');
      expect(
        hits.where((uri) => uri.queryParameters['wd'] == 'Fixture title'),
        isNotEmpty,
      );
      expect(environment.metadataRequests, isEmpty);
    }, _RealHttpOverrides()),
  );

  testWidgets(
    'detail exposes a selectable line and enabled episode after scrolling past the lazy hero',
    (tester) async {
      final environment = (await tester.runAsync(
        MvpFixtureEnvironment.create,
      ))!;
      addTearDown(() => environment.dispose(tester));
      final vod = Vod.fromJson({
        'vod_id': 'fixture-id',
        'vod_name': 'Fixture title',
        'vod_play_from': 'fixture',
        'vod_play_url': 'Episode 1\$http://127.0.0.1/fixture.m3u8',
      })!;
      environment.state.seedDetailForTest(vod: vod);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(state: environment.state, vod: vod),
        ),
      );
      await tester.pumpAndSettle();
      final lineChip = find.byKey(const ValueKey('tmdb-line-fixture'));
      expect(
        lineChip,
        findsNothing,
        reason: 'hero occupies the first lazy viewport',
      );
      await tester.scrollUntilVisible(
        lineChip,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: lineChip, matching: find.textContaining('fixture')),
        findsWidgets,
      );
      expect(tester.widget<ChoiceChip>(lineChip).onSelected, isNotNull);
      await tester.tap(lineChip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(lineChip).selected, isTrue);
      final episode = find.byKey(const ValueKey('tmdb-episode-card-fixture-0'));
      await tester.scrollUntilVisible(
        episode,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(episode.hitTestable(), findsOneWidget);
      expect(tester.widget<OutlinedButton>(episode).onPressed, isNotNull);
    },
  );

  testWidgets(
    'teardown unmounts state listeners and dismisses live callbacks',
    (tester) async {
      final environment = await tester.runAsync(MvpFixtureEnvironment.create);
      final fixture = environment!;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(children: [_StateListener(fixture), const ToastHost()]),
        ),
      );
      var dismissals = 0;
      showToast(
        'fixture notice',
        onDismiss: () {
          fixture.state.clearNotice();
          dismissals++;
        },
      );

      await tester.pump();
      expect(find.text('fixture notice'), findsOneWidget);
      await fixture.dispose(tester);
      expect(find.byType(_StateListener), findsNothing);
      expect(dismissals, 1);
      expect(toastCenter.toasts, isEmpty);
      expect(fixture.directory.existsSync(), isFalse);
      await tester.pump(const Duration(seconds: 31));
      expect(dismissals, 1);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'production root keeps Splash until its own bootstrap completes',
    (tester) => _withBoundaryFiles((files) async {
      final gate = Completer<void>();
      final environment = (await tester.runAsync(
        () => MvpFixtureEnvironment.create(
          bootstrap: false,
          bootstrapGate: gate.future,
          controlledBootstrap: true,
        ),
      ))!;
      addTearDown(() => environment.dispose(tester));
      expect(environment.bootstrapCalls, 0);
      await tester.pumpWidget(
        WebHtvApp(stateFactory: environment.stateForRoot),
      );
      await tester.pump();
      expect(find.text('正在初始化…'), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      expect(environment.bootstrapCalls, 1);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('使用边界提示'), findsOneWidget);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('正在初始化…'), findsNothing);
      expect(find.byType(ToastHost), findsOneWidget);
      expect(environment.bootstrapCalls, 1);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      expect(environment.disposeCalls, 1);
      await environment.dispose(tester);
      expect(environment.disposeCalls, 1);
    }),
  );

  testWidgets(
    'unmounting the production root leaves no late disposed-state callback',
    (tester) => _withBoundaryFiles((files) async {
      final environment = (await tester.runAsync(
        () => MvpFixtureEnvironment.create(
          bootstrap: false,
          controlledBootstrap: true,
        ),
      ))!;
      addTearDown(() => environment.dispose(tester));
      final state = environment.state;
      await tester.pumpWidget(
        WebHtvApp(stateFactory: environment.stateForRoot),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('使用边界提示'), findsOneWidget);
      expect(find.byType(AppShell), findsOneWidget);
      var dismissals = 0;
      showToast(
        'root notice',
        onDismiss: () {
          dismissals++;
          state.clearNotice();
        },
      );
      await tester.pump();
      expect(find.text('root notice'), findsOneWidget);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(const MaterialApp(home: ToastHost()));
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(toastCenter.toasts, isEmpty);
      expect(dismissals, 1, reason: '通知在状态存活时收束，不能延后到下一会话');
      expect(tester.takeException(), isNull);
      expect(environment.disposeCalls, 1);
    }),
  );

  testWidgets(
    'pending boundary read cannot update an unmounted root shell',
    (tester) => _withBoundaryFiles((files) async {
      files.file.existsGate = Completer<bool>();
      final environment = (await tester.runAsync(
        () => MvpFixtureEnvironment.create(
          bootstrap: false,
          controlledBootstrap: true,
        ),
      ))!;
      addTearDown(() => environment.dispose(tester));
      await tester.pumpWidget(
        WebHtvApp(stateFactory: environment.stateForRoot),
      );
      await tester.pump();
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('使用边界提示'), findsNothing);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      files.file.existsGate!.complete(false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'pending boundary acknowledgement cannot update an unmounted root shell',
    (tester) => _withBoundaryFiles((files) async {
      files.file.writeGate = Completer<File>();
      final environment = (await tester.runAsync(
        () => MvpFixtureEnvironment.create(
          bootstrap: false,
          controlledBootstrap: true,
        ),
      ))!;
      addTearDown(() => environment.dispose(tester));
      await tester.pumpWidget(
        WebHtvApp(stateFactory: environment.stateForRoot),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('使用边界提示'), findsOneWidget);
      await tester.tap(find.text('我已了解并继续'));
      expect(files.file.writeCalls, 1);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      files.file.writeGate!.complete(files.file);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }),
  );
}
