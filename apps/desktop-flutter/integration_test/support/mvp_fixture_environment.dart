import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/toast.dart';

/// Only optional metadata is synthetic; site HTTP, SQLite and playback stay real.
class MvpFixtureEnvironment {
  MvpFixtureEnvironment._(this.directory, this.paths);

  final Directory directory;
  final AppPaths paths;
  late final AppState state;
  final _states = <_FixtureAppState>[];
  bool _rootOwnsState = false;
  bool _disposed = false;

  _FixtureAppState get _fixtureState => state as _FixtureAppState;
  int get bootstrapCalls => _fixtureState.bootstrapCalls;
  int get disposeCalls => _fixtureState.disposeCalls;
  AppState stateForRoot() {
    if (_rootOwnsState || bootstrapCalls != 0) {
      throw StateError('Root requires a new, unbootstrapped fixture state');
    }
    _rootOwnsState = true;
    return state;
  }

  final _previousLogDirectory = LogService.logDirectoryOverride;
  final metadataRequests = <Uri>[];

  static Future<MvpFixtureEnvironment> create({
    bool bootstrap = true,
    Future<void>? bootstrapGate,
    bool controlledBootstrap = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'webhtv-mvp-fixture-',
    );
    final environment = MvpFixtureEnvironment._(
      directory,
      AppPaths.resolve(
        overrides: {
          'config': '${directory.path}/config',
          'data': '${directory.path}/data',
          'cache': '${directory.path}/cache',
          'state': '${directory.path}/logs',
        },
      ),
    );
    final state = environment._newState(
      bootstrapGate: bootstrapGate,
      controlledBootstrap: controlledBootstrap,
    );
    environment.state = state;
    if (bootstrap) await state.bootstrap();
    return environment;
  }

  _FixtureAppState _newState({
    Future<void>? bootstrapGate,
    bool controlledBootstrap = false,
  }) {
    final state = _FixtureAppState(
      paths,
      metadataRequests,
      bootstrapGate,
      controlledBootstrap,
    );
    _states.add(state);
    return state;
  }

  Future<AppState> createState() async {
    final state = _newState();
    await state.bootstrap();
    return state;
  }

  Future<void> disposeState(AppState state) async {
    if (!_states.remove(state)) return;
    final fixture = state as _FixtureAppState;
    if (!fixture.isDisposed) {
      if (_rootOwnsState && identical(state, this.state)) {
        throw StateError('Unmount WebHtvApp before releasing its environment');
      }
      state.endSessionCleanly();
      state.dispose();
    }
    await state.pythonEnvironmentIdle;
  }

  Future<void> dispose([WidgetTester? tester]) async {
    if (_disposed) return;
    // Toast callbacks retain AppState even after their original page is gone.
    dismissAllToasts();
    if (tester != null) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    Future<void> release() async {
      for (final state in _states.toList()) {
        await disposeState(state);
      }
      LogService.logDirectoryOverride = _previousLogDirectory;
      // AppState.dispose() 是同步的：sidecar / 日志 / 运行时收尾仍可能在跑，
      // 立刻递归删除会撞上 ENOTEMPTY 或「另一个程序正在使用此文件」。
      // 与仓库既有约定一致：有界重试（10s），用尽仍失败就原样抛出。
      for (var attempt = 1; ; attempt++) {
        if (!directory.existsSync()) break;
        try {
          directory.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          if (attempt >= 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      _disposed = true;
    }

    if (tester == null) {
      await release();
    } else {
      await tester.runAsync(release);
    }
  }
}

class _FixtureAppState extends AppState {
  _FixtureAppState(
    AppPaths paths,
    this.requests,
    this.bootstrapGate,
    this.controlledBootstrap,
  ) : super(paths: paths, log: LogService());

  final List<Uri> requests;
  final Future<void>? bootstrapGate;
  final bool controlledBootstrap;
  int bootstrapCalls = 0;
  int disposeCalls = 0;
  bool isDisposed = false;

  @override
  Future<void> bootstrap() async {
    bootstrapCalls++;
    if (bootstrapGate != null) await bootstrapGate;
    if (!controlledBootstrap) {
      await super.bootstrap();
      await setExternalMetaEnabled(false);
    }
  }

  late final _metadataClient = _EmptyMetadataClient(requests);
  DetailRecommendationDependencies? _recommendations;

  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      _recommendations ??= DetailRecommendationDependencies.fromServices(
        service: tmdbService,
        cacheDirectory: Directory(paths.cacheDir),
        feedbackFile: File('${paths.configDir}/recommendation-feedback.json'),
        doubanClient: _metadataClient,
        historyChanges: this,
        history: () => [
          for (final row in recentHistory(sourceKey: ''))
            recommendationSeedForHistory(row),
        ],
      );

  @override
  void dispose() {
    disposeCalls++;
    isDisposed = true;
    _recommendations?.close();
    _metadataClient.close();
    super.dispose();
  }
}

class _EmptyMetadataClient extends http.BaseClient {
  _EmptyMetadataClient(this.requests);
  final List<Uri> requests;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode('[]')),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}
