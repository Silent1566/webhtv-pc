import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/direct_spider_registrar.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/unidbg_runtime.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'fixture_support.dart';
import 'support/test_fonts.dart';

import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

class _SeedState extends AppState {
  _SeedState(AppPaths paths) : super(paths: paths);
  @override
  Future<void> loadHome(Site site) async {}
}

// The external entry lookup is deliberately held in the worker, not the UI.
class _HeldEntry extends LocalSpider {
  _HeldEntry(String root, this.started, this.release, this.reads)
    : super(
        manifest: SpiderManifest(
          key: 'other',
          name: 'other',
          runtime: 'jvm',
          entry: 'entry.jar',
          capabilities: const ['home'],
        ),
        manifestPath: p.join(root, 'manifest.json'),
        rootDir: root,
        entryPath: p.join(root, 'entry.jar'),
      );
  final String started;
  final String release;
  final String reads;
  @override
  bool get entryExists {
    File(
      reads,
    ).writeAsStringSync('${Isolate.current.hashCode}\n', mode: FileMode.append);
    File(started).writeAsStringSync('started');
    final clock = Stopwatch()..start();
    while (!File(release).existsSync() && clock.elapsedMilliseconds < 10000) {
      sleep(const Duration(milliseconds: 10));
    }
    return true;
  }
}

final _captureDirectory =
    Platform.environment['CURRENT_SITE_READINESS_CAPTURE_DIR'] ?? '';

Future<void> _loadCaptureFonts(WidgetTester tester) async {
  if (_captureDirectory.isEmpty) return;
  await tester.runAsync(() async {
    for (final family in ['Roboto', 'Microsoft YaHei UI', 'Microsoft YaHei']) {
      await loadFixtureFonts(cjkFamily: family);
    }
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDirectory.isEmpty) return;
  await tester.runAsync(() async {
    final file = File(p.join(_captureDirectory, '$name.png'));
    await file.parent.create(recursive: true);
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _deleteTempWhenReleased(Directory temp) async {
  const attempts = 100;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    if (!temp.existsSync()) return;
    try {
      temp.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == attempts) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class _ShellState extends AppState {
  _ShellState(AppPaths paths)
    : super(
        paths: paths,
        jvmSidecarHostPath: p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-jvm',
          'host.jar',
        ),
        httpClient: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      ) {
    debugCspProvisionOverride = (_, {onEntry, onProgress}) async =>
        const CspProbeReport();
  }
  final Zone ioZone = Zone.current;
  int installs = 0;
  int homes = 0;
  @override
  bool get shellRuntimeInstalled => installs > 0;
  @override
  Future<UnidbgRuntimeInstall> installShellRuntime({
    void Function(UnidbgRuntimeProgress)? onProgress,
  }) async {
    installs++;
    return const UnidbgRuntimeInstall(
      installed: true,
      dir: 'fixture',
      bytes: 0,
    );
  }

  @override
  Future<void> loadHome(Site site) async {
    homes++;
    await ioZone.run(() => super.loadHome(site));
  }
}

class _ShellProbe extends CspJarProbe {
  _ShellProbe(this.discovery, this.install, String root, CspJvmBinding binding)
    : super(root: root, binding: binding);
  final Future<List<ShellJarTarget>> Function() discovery;
  final Future<CspProbeReport> Function() install;
  @override
  Future<List<ShellJarTarget>> discoverShellTargets(
    AppConfig config, {
    bool refresh = false,
  }) => discovery();
  @override
  Future<CspProbeReport> unpackSelected(
    AppConfig config, {
    required Set<String> jarUrls,
    void Function(ShellUnpackTick)? onProgress,
  }) => install();
}

class _CurrentCspProbe extends CspJarProbe {
  _CurrentCspProbe(
    CspJvmBinding binding,
    String root,
    this.held,
    this.started,
    this.seen,
  ) : super(binding: binding, root: root);
  final Future<void> held;
  final Completer<void> started;
  final List<String> seen;
  final List<String> shells = [];
  @override
  Future<CspProbeReport> materialize(
    AppConfig config, {
    void Function(ShellUnpackTick)? onProgress,
    void Function(CspProbeEntry)? onEntry,
  }) async {
    final entries = <CspProbeEntry>[];
    for (final site in config.sites) {
      seen.add(site.key);
      if (site.key != 'shell-4') {
        if (!started.isCompleted) started.complete();
        await held;
      }
      shells.add(site.key);
      final entry = CspProbeEntry(
        siteKey: site.key,
        outcome: CspProbeOutcome.needsShellRuntime,
      );
      entries.add(entry);
      onEntry?.call(entry);
    }
    return CspProbeReport(entries: entries);
  }

  @override
  Future<List<ShellJarTarget>> discoverShellTargets(
    AppConfig config, {
    bool refresh = false,
  }) async => [
    for (final key in seen.where((key) => key == 'shell-4'))
      ShellJarTarget(
        jarUrl: 'https://fixture.test/4.jar',
        state: ShellTargetState.needsRuntime,
        siteKeys: [key],
      ),
  ];
}

void _readinessTests() {
  late Directory temp;
  late AppState state;
  late HttpServer server;
  late File release;
  late File started;
  late File reads;
  var homeCalls = 0;
  var categoryCalls = 0;

  setUp(() async {
    homeCalls = 0;
    categoryCalls = 0;
    temp = await Directory.systemTemp.createTemp('current-site-');
    release = File(p.join(temp.path, 'release'));
    started = File(p.join(temp.path, 'started'));
    reads = File(p.join(temp.path, 'reads'));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final home = request.uri.path.endsWith('/home');
      if (home) homeCalls++;
      if (request.uri.path.endsWith('/category')) categoryCalls++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'class': [
            {'type_id': '1', 'type_name': '电影'},
          ],
          'list': home
              ? []
              : [
                  {
                    'vod_id': 'current-vod',
                    'vod_name': '当前站点影片',
                    'vod_pic': '',
                  },
                ],
          'page': 1,
          'pagecount': 1,
        }),
      );
      await request.response.close();
    });
    final paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final seed = _SeedState(paths);
    seed.debugDirectProbeOverride = (_) async => {};
    await seed.bootstrap();
    expect(
      await seed.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'current',
              'name': '当前站点',
              'type': 3,
              'api': 'http://127.0.0.1:${server.port}/spider/current',
            },
            {
              'key': 'other',
              'name': '无关慢站点',
              'type': 3,
              'api': 'https://fixture.test/other.js',
            },
          ],
        }),
      ),
      isTrue,
    );
    seed.dispose();
    await seed.pythonEnvironmentIdle;
    state = AppState(
      paths: paths,
      httpClient: MockClient((request) async {
        final home = request.url.path.endsWith('/home');
        if (home) homeCalls++;
        if (request.url.path.endsWith('/category')) categoryCalls++;
        return http.Response(
          jsonEncode({
            'class': [
              {'type_id': '1', 'type_name': '电影'},
            ],
            'list': home
                ? []
                : [
                    {
                      'vod_id': 'current-vod',
                      'vod_name': '当前站点影片',
                      'vod_pic': '',
                    },
                  ],
            'page': 1,
            'pagecount': 1,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    state.debugDirectProbeOverride = (_) async => {
      'other': _HeldEntry(temp.path, started.path, release.path, reads.path),
    };
    await state.bootstrap();
  });

  tearDown(() async {
    release.writeAsStringSync('release');
    state.dispose();
    await state.pythonEnvironmentIdle;
    await server.close(force: true);
    LogService.logDirectoryOverride = null;
    await temp.delete(recursive: true);
  });

  Future<void> startBackground(WidgetTester tester) async {
    await tester.runAsync(() async {
      // Bootstrap registration is queued to the next event turn.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state.siteItems;
      final clock = Stopwatch()..start();
      while (!started.existsSync() && clock.elapsedMilliseconds < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(started.existsSync(), isTrue);
    });
  }

  Future<GlobalKey> mountBrowse(WidgetTester tester) async {
    await _loadCaptureFonts(tester);
    tester.view.physicalSize = const Size(1303, 791);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (_, _) => BrowsePage(state: state),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return key;
  }

  testWidgets('real Browse never reports unsupported for pending preparation', (
    tester,
  ) async {
    await startBackground(tester);
    await tester.runAsync(() async {
      unawaited(state.selectSite(state.effectiveConfig!.sites.last));
    });
    final key = await mountBrowse(tester);
    await _capture(tester, key, 'browse-pending');
    expect(find.text('站点运行时未安装或不支持'), findsNothing);
    expect(find.textContaining('准备'), findsWidgets);
    await tester.runAsync(() async {
      release.writeAsStringSync('release');
      await state.pythonEnvironmentIdle;
    });
  });

  testWidgets('current home and category finish before held unrelated worker', (
    tester,
  ) async {
    await startBackground(tester);
    final key = await mountBrowse(tester);
    var completed = false;
    var completedMs = -1;
    final clock = Stopwatch()..start();
    await tester.runAsync(() async {
      unawaited(
        state.loadHome(state.selectedSite!).then((_) {
          completed = true;
          completedMs = clock.elapsedMilliseconds;
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await _capture(tester, key, 'browse-current-ready');
    // ignore: avoid_print
    print(
      'current completion=${completedMs}ms capture=${clock.elapsedMilliseconds}ms: completed=$completed home=$homeCalls category=$categoryCalls error=${state.lastError?.logLine} unrelatedReleased=${release.existsSync()}',
    );
    expect(
      completed,
      isTrue,
      reason: 'current must complete while unrelated worker remains held',
    );
    expect(release.existsSync(), isFalse);
    expect(homeCalls, 1);
    expect(categoryCalls, 1);
    expect(state.categoryResult?.list.single.vodName, '当前站点影片');
    expect(find.text('当前站点影片'), findsOneWidget);
    expect(
      reads.readAsLinesSync().where(
        (line) => line == '${Isolate.current.hashCode}',
      ),
      isEmpty,
    );
    await tester.runAsync(() async {
      release.writeAsStringSync('release');
      await state.pythonEnvironmentIdle;
    });
    expect(state.siteItems.last.availability.preparing, isFalse);
    expect(
      reads.readAsLinesSync(),
      hasLength(1),
      reason: 'same-site background scan is single flight',
    );
    await tester.pump();
    expect(
      find.text('当前站点影片'),
      findsOneWidget,
      reason: 'unrelated readiness completion preserves current content',
    );
  });
}

void _shellTests() {
  late Directory temp;
  late HttpServer server;
  _ShellState? current;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('shell-app-flow-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'class': [],
          'list': [
            {'vod_id': 'shell-content', 'vod_name': '解包后的影片', 'vod_pic': ''},
          ],
        }),
      );
      await request.response.close();
    });
    current = null;
  });
  tearDown(() async {
    if (current != null) {
      current!.dispose();
    }
    await server.close(force: true);
    LogService.logDirectoryOverride = null;
    await temp.delete(recursive: true);
  });
  for (final action in [
    'cancel',
    'confirm',
    'switch',
    'dispose',
    'cached',
    'failure',
    'switch-unpack',
    'dispose-unpack',
    'selected',
  ]) {
    testWidgets('real AppShell restored VOD late shell discovery: $action', (
      tester,
    ) async {
      final dir = Directory(p.join(temp.path, 'shell'))
        ..createSync(recursive: true);
      final paths = AppPaths.resolve(
        overrides: {
          'config': dir.path,
          'data': dir.path,
          'cache': p.join(dir.path, 'cache'),
          'state': p.join(dir.path, 'logs'),
        },
      );
      await tester.runAsync(() async {
        final seed = _SeedState(paths);
        seed.debugCspProbeOverride = (_) async => const CspProbeReport();
        await seed.bootstrap();
        expect(
          await seed.importConfig(
            jsonEncode({
              'sites': [
                {
                  'key': 'shell',
                  'name': '待解包站点',
                  'type': 3,
                  'api': 'csp_fixture.FixtureSpider',
                  'ext': 'http://127.0.0.1:${server.port}',
                },
                {
                  'key': 'other-http',
                  'name': '另一个站点',
                  'type': 4,
                  'api': 'https://fixture.test/api',
                },
              ],
            }),
          ),
          isTrue,
        );
        seed.dispose();
        await seed.pythonEnvironmentIdle;
      });
      late _ShellState shell;
      await tester.runAsync(() async {
        shell = _ShellState(paths);
      });
      current = shell;
      final discovery = Completer<List<ShellJarTarget>>();
      var installed = false;
      var unpackCalls = 0;
      final unpackRelease = Completer<void>();
      shell.debugCspProbeFactoryOverride = (binding, _) => _ShellProbe(
        () async => installed
            ? [
                const ShellJarTarget(
                  jarUrl: 'https://fixture.test/shell.jar',
                  state: ShellTargetState.installed,
                  siteKeys: ['shell'],
                ),
              ]
            : discovery.future,
        () => Zone.root.run(() async {
          unpackCalls++;
          if (action == 'switch-unpack' || action == 'dispose-unpack') {
            await unpackRelease.future;
          }
          if (action == 'failure') {
            return const CspProbeReport(
              entries: [
                CspProbeEntry(
                  siteKey: 'shell',
                  outcome: CspProbeOutcome.unpackFailed,
                  message: 'fixture 解包失败阶段',
                ),
              ],
            );
          }
          final classes = p.join(dir.path, 'compiled');
          final host = p.join(
            repositoryRoot.path,
            'sidecars',
            'spider-host-jvm',
            'host.jar',
          );
          final result = await Process.run('javac', [
            '-encoding',
            'UTF-8',
            '-cp',
            host,
            '-d',
            classes,
            p.join(
              repositoryRoot.path,
              'sidecars',
              'spider-host-jvm',
              'spiders',
              'fixture',
              'FixtureSpider.java',
            ),
          ]);
          if (result.exitCode != 0) throw StateError('${result.stderr}');
          final resultInstall = await JarIntake.install(
            sourcePath: classes,
            targetDir: binding.directoryFor('shell'),
            siteKey: 'shell',
            className: 'fixture.FixtureSpider',
            manualOverride: true,
          );
          if (!resultInstall.ok) {
            throw StateError(resultInstall.error ?? 'install failed');
          }
          installed = true;
          return const CspProbeReport(
            entries: [
              CspProbeEntry(
                siteKey: 'shell',
                outcome: CspProbeOutcome.unpacked,
              ),
            ],
          );
        }),
        shell.spiderRegistry.root,
        binding,
      );
      await tester.runAsync(() async {
        await shell.bootstrap();
        // The real JVM fixture serves home from this isolated loopback server.
        final selected = shell.selectedSite!;
        expect(selected.key, 'shell');
      });
      tester.view.physicalSize = const Size(1303, 791);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      File(p.join(dir.path, 'usage-boundary-accepted'))
          .writeAsStringSync('fixture');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AppShell(state: shell, startup: const StartupArguments()),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pump();
      await tester.tap(find.text('点播').first);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('shell-unpack-selection')),
        findsNothing,
      );
      if (action == 'selected') {
        await tester.runAsync(() async {
          unawaited(shell.selectSite(shell.selectedSite!));
        });
      }
      if (action == 'switch') {
        await tester.runAsync(() async {
          unawaited(shell.selectSite(shell.effectiveConfig!.sites.last));
        });
        await tester.pump();
      }
      if (action == 'dispose') {
        await tester.pumpWidget(const SizedBox());
        shell.dispose();
        current = null;
      }
      await tester.runAsync(() async {
        discovery.complete([
          ShellJarTarget(
            jarUrl: 'https://fixture.test/shell.jar',
            state: action == 'cached'
                ? ShellTargetState.unpacked
                : ShellTargetState.needsRuntime,
            siteKeys: const ['shell'],
          ),
        ]);
        await shell.shellTargetsProbe;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (action == 'switch' || action == 'dispose') {
        toastCenter.dismissAll();
        expect(
          find.byKey(const ValueKey('shell-unpack-selection')),
          findsNothing,
        );
        expect(unpackCalls, 0);
        expect(shell.installs, 0);
        if (action == 'switch') {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            shell.dispose();
          });
          current = null;
        }
        return;
      }
      expect(
        find.byKey(const ValueKey('shell-unpack-selection')),
        findsOneWidget,
      );
      if (action == 'cancel') {
        await tester.tap(
          find.byKey(const ValueKey('shell-unpack-selection-cancel')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(unpackCalls, 0);
        expect(shell.installs, 0);
      } else {
        final before = shell.homes;
        await tester.tap(
          find.byKey(const ValueKey('shell-unpack-selection-start')),
        );
        if (action == 'switch-unpack' || action == 'dispose-unpack') {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pump();
          if (action == 'switch-unpack') {
            await tester.runAsync(() async {
              unawaited(shell.selectSite(shell.effectiveConfig!.sites.last));
            });
          } else {
            await tester.pumpWidget(const SizedBox());
            shell.dispose();
            current = null;
          }
          final homes = shell.homes;
          unpackRelease.complete();
          for (var i = 0; i < 35 && !installed; i++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 80));
            });
            await tester.pump();
          }
          expect(installed, isTrue);
          expect(
            shell.homes,
            homes,
            reason: 'unpack must not reload switched-away or disposed state',
          );
          if (current != null) {
            await tester.pumpWidget(const SizedBox());
            shell.dispose();
            current = null;
          }
          return;
        }
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 80));
          });
          await tester.pump();
          if (find.text('加固壳解包失败').evaluate().isNotEmpty ||
              (shell.homes > before &&
                  shell.contentPhase != LoadPhase.loading)) {
            break;
          }
        }
        // ignore: avoid_print
        print('SHELL installed=$installed unpackCalls=$unpackCalls');
        // ignore: avoid_print
        print(
          'SHELL result homes=${shell.homes} before=$before err=${shell.lastError} phase=${shell.contentPhase}',
        );
        expect(unpackCalls, 1);
        expect(shell.installs, action == 'cached' ? 0 : 1);
        if (action == 'failure') {
          expect(find.text('加固壳解包失败'), findsOneWidget);
          expect(shell.homes, before);
        } else {
          expect(find.text('加固壳解包失败'), findsNothing);
          expect(
            shell.homes,
            before + 1,
            reason: 'only same current site reloads exactly once',
          );
          expect(shell.siteItems.first.availability.preparing, isFalse);
          expect(
            shell.contentPhase,
            LoadPhase.ready,
            reason: shell.lastError?.logLine,
          );
          expect(shell.homeResult?.list.single.vodName, '解包后的影片');
          await tester.tap(
            find.byKey(const ValueKey('shell-unpack-progress-close')),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('解包后的影片'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('shell-unpack-selection')),
            findsNothing,
          );
        }
      }
      toastCenter.dismissAll();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await shell.stopSpider('shell');
        shell.dispose();
      });
      await tester.pump();
      current = null;
    });
  }
}

void _directTests() {
  test('fifth missing CSP current source discovers shell while earlier four URLs remain held', () async {
    final temp = await Directory.systemTemp.createTemp('current-fifth-csp-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final seed = _SeedState(paths);
    seed.debugCspProbeOverride = (_) async => const CspProbeReport();
    await seed.bootstrap();
    expect(
      await seed.importConfig(
        jsonEncode({
          'sites': [
            for (var i = 0; i < 5; i++)
              {
                'key': 'shell-$i',
                'name': 'shell-$i',
                'type': 3,
                'api': 'csp_Demo',
                'jar': 'https://fixture.test/$i.jar',
              },
          ],
        }),
      ),
      isTrue,
    );
    seed.dispose();
    await seed.pythonEnvironmentIdle;
    final held = Completer<void>();
    final started = Completer<void>();
    final seen = <String>[];
    late AppState state;
    state = AppState(paths: paths);
    state.debugCspProbeFactoryOverride = (binding, _) => _CurrentCspProbe(
      binding,
      state.spiderRegistry.root,
      held.future,
      started,
      seen,
    );
    try {
      await state.bootstrap();
      await started.future;
      final fifth = state.effectiveConfig!.sites.last;
      await state.selectSite(fifth).timeout(const Duration(seconds: 2));
      state.enterCurrentVod();
      expect(held.isCompleted, isFalse);
      expect(state.pendingShellUnpackForSite, fifth.key);
      expect(seen.where((key) => key == fifth.key), hasLength(1));
    } finally {
      held.complete();
      state.dispose();
      await state.pythonEnvironmentIdle;
      LogService.logDirectoryOverride = null;
      await temp.delete(recursive: true);
    }
  });

  test(
    'failed foreground direct materialization can retry after HTTP recovers',
    () async {
      final temp = await Directory.systemTemp.createTemp('direct-retry-');
      final config = AppConfig(
        sites: [
          Site(
            key: 'retry',
            name: 'retry',
            type: 3,
            api: 'https://fixture.test/retry.py',
          ),
        ],
      );
      var calls = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: SpiderManifestRegistry(root: temp.path, log: LogService()),
        client: MockClient(
          (_) async => ++calls == 1
              ? http.Response('', 503)
              : http.Response('def home(): return {}', 200),
        ),
      );
      try {
        expect(
          await registrar.materializeSite(config, config.sites.single),
          isNull,
        );
        expect(
          (await registrar.materializeSite(config, config.sites.single))?.key,
          'retry',
        );
        expect(calls, 2);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test('AppState current direct home reaches real sidecar before background other download completes', () async {
    final temp = await Directory.systemTemp.createTemp('direct-home-priority-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final seed = _SeedState(paths);
    seed.debugDirectProbeOverride = (_) async => {};
    await seed.bootstrap();
    expect(
      await seed.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'other',
              'name': 'other',
              'type': 3,
              'api': 'https://fixture.test/other.js',
            },
            {
              'key': 'current-js',
              'name': 'current',
              'type': 3,
              'api': 'https://fixture.test/current.js',
            },
          ],
        }),
      ),
      isTrue,
    );
    seed.dispose();
    await seed.pythonEnvironmentIdle;
    final held = Completer<http.Response>();
    final started = Completer<void>();
    var downloads = 0;
    final state = AppState(
      paths: paths,
      jsSidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-js',
        'host.js',
      ),
      httpClient: MockClient((request) async {
        if (request.url.path == '/other.js') {
          started.complete();
          return held.future;
        }
        downloads++;
        return http.Response(
          'module.exports.default = { home: function() { return {class: [{type_id: "1", type_name: "Movie"}], list: []}; }, category: function() { return {list: [{vod_id: "direct-home", vod_name: "Direct current ready", vod_pic: ""}]}; }, detail: function() { return {list: []}; } };',
          200,
        );
      }),
    );
    try {
      await state.bootstrap();
      await started.future;
      final selected = state.effectiveConfig!.sites.last;
      final clock = Stopwatch()..start();
      await state.selectSite(selected).timeout(const Duration(seconds: 5));
      expect(held.isCompleted, isFalse);
      expect(
        state.categoryResult?.list.single.vodName,
        'Direct current ready',
        reason: state.lastError?.logLine,
      );
      expect(downloads, 1);
      // ignore: avoid_print
      print(
        'actual direct current home=${clock.elapsedMilliseconds}ms otherReleased=${held.isCompleted} downloads=$downloads',
      );
      held.complete(http.Response('module.exports={};', 200));
      await state.registerDirectSpiders();
      expect(
        state.debugDirectSpiders.keys,
        containsAll(['current-js', 'other']),
      );
      expect(downloads, 1);
    } finally {
      if (!held.isCompleted) held.complete(http.Response('', 404));
      await state.stopSpider('current-js');
      state.dispose();
      await state.pythonEnvironmentIdle;
      LogService.logDirectoryOverride = null;
      await temp.delete(recursive: true);
    }
  });

  test('current materialization completes while earlier background download is held and shares same-site work', () async {
    final temp = await Directory.systemTemp.createTemp('direct-priority-');
    final slow = Completer<http.Response>();
    final started = Completer<void>();
    final config = AppConfig(
      sites: [
        Site(
          key: 'slow',
          name: 'slow',
          type: 3,
          api: 'https://fixture.test/slow.py',
        ),
        Site(
          key: 'current',
          name: 'current',
          type: 3,
          api: 'https://fixture.test/current.py',
        ),
      ],
    );
    final requests = <String, int>{};
    final published = <String>[];
    final registrar = DirectSpiderRegistrar(
      root: temp.path,
      registry: SpiderManifestRegistry(root: temp.path, log: LogService()),
      client: MockClient((request) async {
        requests.update(
          request.url.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        if (request.url.path == '/slow.py') {
          started.complete();
          return slow.future;
        }
        return http.Response('def home(): return {}', 200);
      }),
    );
    try {
      final background = registrar.materialize(
        config,
        onRegistered: (local) => published.add(local.key),
      );
      await started.future;
      final result = await Future.wait([
        registrar.materializeSite(config, config.sites.last),
        registrar.materializeSite(config, config.sites.last),
      ]);
      expect(slow.isCompleted, isFalse);
      expect(result.every((local) => local?.key == 'current'), isTrue);
      expect(requests['/current.py'], 1);
      slow.complete(http.Response('def home(): return {}', 200));
      final all = await background;
      expect(all.keys, containsAll(['slow', 'current']));
      expect(published, ['slow', 'current']);
      expect(
        requests['/current.py'],
        1,
        reason: 'later background work reuses current materialization, not redownload',
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

void _preparationLifetimeTests() {
  late Directory temp;
  late AppPaths paths;
  AppState? state;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('preparation-lifetime-');
    paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    state = null;
  });
  tearDown(() async {
    if (state != null) {
      state!.dispose();
      await state!.pythonEnvironmentIdle;
    }
    LogService.logDirectoryOverride = null;
    await _deleteTempWhenReleased(temp);
  });
  Future<void> seed(List<Map<String, Object?>> sites) async {
    final seed = _SeedState(paths);
    seed.debugDirectProbeOverride = (_) async => {};
    seed.debugCspProbeOverride = (_) async => const CspProbeReport();
    await seed.bootstrap();
    expect(await seed.importConfig(jsonEncode({'sites': sites})), isTrue);
    seed.dispose();
    await seed.pythonEnvironmentIdle;
  }

  Future<GlobalKey> mount(WidgetTester tester) async {
    await _loadCaptureFonts(tester);
    tester.view.physicalSize = const Size(1303, 791);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state!,
              builder: (_, _) => BrowsePage(state: state!),
            ),
          ),
        ),
      ),
    );
    return key;
  }

  testWidgets(
    'direct pending beyond yield timeout stays preparing and late home resumes before unrelated download',
    (tester) async {
      late Completer<http.Response> other;
      late Completer<http.Response> current;
      late Completer<void> otherStarted;
      late Completer<void> currentStarted;
      await tester.runAsync(() async {
        other = Completer();
        current = Completer();
        otherStarted = Completer();
        currentStarted = Completer();
      });
      var downloads = 0;
      await tester.runAsync(() async {
        await seed([
          {
            'key': 'other',
            'name': 'other',
            'type': 3,
            'api': 'https://fixture.test/other.js',
          },
          {
            'key': 'current-js',
            'name': '当前下载站点',
            'type': 3,
            'api': 'https://fixture.test/current.js',
          },
        ]);
        state = AppState(
          paths: paths,
          jsSidecarHostPath: p.join(
            repositoryRoot.path,
            'sidecars',
            'spider-host-js',
            'host.js',
          ),
          httpClient: MockClient((request) async {
            if (request.url.path == '/other.js') {
              if (!otherStarted.isCompleted) otherStarted.complete();
              return other.future;
            }
            downloads++;
            if (!currentStarted.isCompleted) currentStarted.complete();
            return current.future;
          }),
        )..debugDirectReadyTimeout = const Duration(milliseconds: 30);
        await state!.bootstrap();
        await otherStarted.future;
      });
      final key = await mount(tester);
      try {
        await tester.runAsync(() async {
          unawaited(state!.selectSite(state!.effectiveConfig!.sites.last));
          await currentStarted.future;
          state!.siteItems;
          unawaited(state!.loadHome(state!.selectedSite!));
          unawaited(state!.loadHome(state!.selectedSite!));
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pump();
        final pendingUnsupported = find
            .text('站点运行时未安装或不支持')
            .evaluate()
            .isNotEmpty;
        final pendingPreparing = state!.siteItems.last.availability.preparing;
        await _capture(tester, key, 'run3-direct-pending');
        final clock = Stopwatch()..start();
        await tester.runAsync(() async {
          current.complete(
            http.Response(
              'module.exports.default={home:function(){return {class:[{type_id:"1",type_name:"Movie"}],list:[]};},category:function(){return {list:[{vod_id:"late-current",vod_name:"下载后自动加载",vod_pic:""}]};},detail:function(){return {list:[]};}};',
              200,
              headers: {
                'content-type': 'application/javascript; charset=utf-8',
              },
            ),
          );
        });
        for (var i = 0; i < 50 && state!.categoryResult == null; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          });
          await tester.pump();
        }
        final homeCount = state!.log.entries
            .where(
              (entry) => entry.message.startsWith('首页加载成功 site=current-js'),
            )
            .length;
        final categoryCount = state!.log.entries
            .where(
              (entry) => entry.message.startsWith('分类加载成功 site=current-js'),
            )
            .length;
        // ignore: avoid_print
        print(
          'direct late result=${clock.elapsedMilliseconds}ms pendingUnsupported=$pendingUnsupported preparing=$pendingPreparing home=$homeCount category=$categoryCount downloads=$downloads unrelatedReleased=${other.isCompleted}',
        );
        await _capture(tester, key, 'run3-direct-ready');
        expect(pendingUnsupported, isFalse);
        expect(pendingPreparing, isTrue);
        expect(find.text('站点运行时未安装或不支持'), findsNothing);
        expect(other.isCompleted, isFalse);
        expect(state!.categoryResult?.list.single.vodName, '下载后自动加载');
        expect(find.text('下载后自动加载'), findsOneWidget);
        expect(homeCount, 1);
        expect(categoryCount, 1);
        expect(downloads, 1);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          if (!current.isCompleted) current.complete(http.Response('', 503));
          if (!other.isCompleted) other.complete(http.Response('', 503));
          await state!.stopSpider('current-js');
          state!.dispose();
          await state!.pythonEnvironmentIdle;
          state = null;
        });
      }
    },
  );

  for (final action in ['failure', 'switch', 'config', 'dispose']) {
    testWidgets(
      'late direct completion handles $action without stale retry or endless preparation',
      (tester) async {
        late Completer<http.Response> other;
        late Completer<http.Response> current;
        late Completer<void> started;
        var downloads = 0;
        await tester.runAsync(() async {
          other = Completer();
          current = Completer();
          started = Completer();
          await seed([
            {
              'key': 'other',
              'name': 'other',
              'type': 3,
              'api': 'https://fixture.test/other.js',
            },
            {
              'key': 'current-js',
              'name': 'current',
              'type': 3,
              'api': 'https://fixture.test/current.js',
            },
            {
              'key': 'safe',
              'name': 'safe',
              'type': 4,
              'api': 'https://fixture.test/api',
            },
          ]);
          state = AppState(
            paths: paths,
            jsSidecarHostPath: p.join(
              repositoryRoot.path,
              'sidecars',
              'spider-host-js',
              'host.js',
            ),
            httpClient: MockClient((request) async {
              if (request.url.path == '/other.js') return other.future;
              if (request.url.path == '/current.js') {
                downloads++;
                if (!started.isCompleted) started.complete();
                return current.future;
              }
              return http.Response(
                '{"class":[],"list":[{"vod_id":"safe","vod_name":"Safe content","vod_pic":""}]}',
                200,
              );
            }),
          )..debugDirectReadyTimeout = const Duration(milliseconds: 30);
          await state!.bootstrap();
          unawaited(state!.selectSite(state!.effectiveConfig!.sites[1]));
          await started.future;
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await mount(tester);
        await tester.pump();
        expect(find.text('站点运行时未安装或不支持'), findsNothing);
        final active = state!;
        try {
          if (action == 'switch') {
            await tester.runAsync(
              () => active.selectSite(active.effectiveConfig!.sites.last),
            );
          }
          if (action == 'config') {
            await tester.runAsync(() async {
              unawaited(
                active.importConfig(
                  jsonEncode({
                    'sites': [
                      {
                        'key': 'replacement',
                        'name': 'replacement',
                        'type': 4,
                        'api': 'https://fixture.test/api',
                      },
                    ],
                  }),
                ),
              );
              await Future<void>.delayed(const Duration(milliseconds: 60));
            });
            await tester.pump();
          }
          if (action == 'dispose') {
            await tester.pumpWidget(const SizedBox());
            active.dispose();
            state = null;
          }
          await tester.runAsync(() async {
            current.complete(http.Response('', 503));
            await Future<void>.delayed(const Duration(milliseconds: 120));
          });
          await tester.pump();
          expect(other.isCompleted, isFalse);
          expect(downloads, 1);
          expect(
            active.log.entries.where(
              (entry) => entry.message.startsWith('首页加载成功 site=current-js'),
            ),
            isEmpty,
          );
          for (
            var i = 0;
            i < 15 &&
                action == 'failure' &&
                active.siteItems[1].availability.preparing;
            i++
          ) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            });
            await tester.pump();
          }
          if (action == 'failure') {
            expect(active.contentPhase, LoadPhase.failed);
            expect(active.siteItems[1].availability.preparing, isFalse);
            expect(find.text('站点运行时未安装或不支持'), findsOneWidget);
            await tester.runAsync(
              () => active.selectSite(active.effectiveConfig!.sites[1]),
            );
            expect(
              downloads,
              2,
              reason: 'explicit retry starts a fresh failed-site attempt, never automatic endless retries',
            );
          } else if (action != 'dispose') {
            expect(
              active.selectedSite?.key,
              action == 'switch' ? 'safe' : 'replacement',
            );
            if (action == 'switch') {
              expect(active.contentPhase, LoadPhase.ready);
            }
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            if (!current.isCompleted) current.complete(http.Response('', 503));
            other.complete(http.Response('', 503));
            if (state != null) {
              state!.dispose();
              state = null;
            }
          });
        }
      },
    );
  }
  testWidgets(
    'settled current CSP fetch failure is terminal while other URL remains provisioning',
    (tester) async {
      late Completer<http.Response> other;
      late Completer<void> otherStarted;
      await tester.runAsync(() async {
        other = Completer();
        otherStarted = Completer();
      });
      var failures = 0;
      await tester.runAsync(() async {
        await seed([
          {
            'key': 'failed-csp',
            'name': '失败的当前站点',
            'type': 3,
            'api': 'csp_Demo',
            'jar': 'https://fixture.test/current.jar',
          },
          {
            'key': 'slow-csp',
            'name': 'other',
            'type': 3,
            'api': 'csp_Demo',
            'jar': 'https://fixture.test/other.jar',
          },
        ]);
        state = AppState(paths: paths);
        state!.debugCspProbeFactoryOverride = (binding, allowUnpack) =>
            CspJarProbe(
              root: state!.spiderRegistry.root,
              binding: binding,
              log: state!.log,
              allowShellUnpack: allowUnpack,
              shellRuntimeInstalled: () => false,
              client: MockClient((request) async {
                if (request.url.path == '/other.jar') {
                  if (!otherStarted.isCompleted) otherStarted.complete();
                  return other.future;
                }
                failures++;
                return http.Response('', 503);
              }),
            );
        await state!.bootstrap();
        await otherStarted.future;
        await state!.selectSite(state!.effectiveConfig!.sites.first);
      });
      final key = await mount(tester);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 70));
      });
      await tester.pump();
      final item = state!.siteItems.first;
      // ignore: avoid_print
      print(
        'CSP settled preparing=${item.availability.preparing} phase=${state!.contentPhase} reason=${item.availability.reason} failures=$failures otherReleased=${other.isCompleted}',
      );
      try {
        await _capture(tester, key, 'run3-csp-terminal');
        expect(other.isCompleted, isFalse);
        expect(item.availability.preparing, isFalse);
        expect(item.availability.available, isFalse);
        expect(item.availability.reason, contains('取回失败'));
        expect(state!.contentPhase, LoadPhase.failed);
        expect(find.text('站点运行时未安装或不支持'), findsOneWidget);
        expect(find.textContaining('取回失败'), findsWidgets);
        expect(find.text('重试'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('重试'));
        });
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump();
          if (state!.contentPhase == LoadPhase.failed &&
              !state!.siteItems.first.availability.preparing) {
            break;
          }
        }
        expect(other.isCompleted, isFalse);
        expect(state!.contentPhase, LoadPhase.failed);
        expect(state!.siteItems.first.availability.preparing, isFalse);
        expect(find.textContaining('取回失败'), findsWidgets);
      } finally {
        final active = state!;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          other.complete(http.Response('', 503));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          active.dispose();
        });
        state = null;
        await tester.pump();
      }
    },
  );
}

void main() {
  group('current readiness', _readinessTests);
  group('shell continuation', _shellTests);
  group('direct priority', _directTests);
  group('preparation lifetime', _preparationLifetimeTests);
}
