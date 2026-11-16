import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

import 'fixture_support.dart';

const _idleTimeout = Duration(minutes: 5);
const _waitBound = Duration(seconds: 10);

/// 手动时钟 + 单次定时器工厂：空闲到点由 [advance] 显式推进。
///
/// 它同时担任 supervisor 的 idleScheduler 与 clock：因此「到点」不依赖真实时间，
/// 也不会在用例结束后留下活动定时器。
class _ManualTime {
  DateTime now = DateTime.utc(2026);
  final List<_ManualTimer> timers = [];

  Timer schedule(Duration delay, void Function() callback) {
    final timer = _ManualTimer(delay, now.add(delay), callback);
    timers.add(timer);
    return timer;
  }

  /// 当前仍在等待的定时器数量。
  int get activeCount => timers.where((timer) => timer.isActive).length;

  /// 已挂载过的延时（按挂载顺序）。
  List<Duration> get delays =>
      timers.map((timer) => timer.delay).toList(growable: false);

  void advance(Duration elapsed) {
    now = now.add(elapsed);
    for (final timer in timers.toList()) {
      if (timer.isActive && !timer.due.isAfter(now)) timer.fire();
    }
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this.due, this.callback);

  final Duration delay;
  final DateTime due;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    callback();
  }
}

class _GateServer {
  _GateServer(this.server) : requests = StreamIterator<HttpRequest>(server);

  final HttpServer server;
  final StreamIterator<HttpRequest> requests;
  String get base => 'http://127.0.0.1:${server.port}';

  Future<HttpRequest> take(String path) async {
    expect(await requests.moveNext().timeout(_waitBound), isTrue);
    final request = requests.current;
    expect(request.uri.path, path);
    return request;
  }

  Future<void> reply(HttpRequest request, Object payload) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  Future<void> close() async {
    await requests.cancel();
    await server.close(force: true);
  }
}

void main() {
  group('bounded sidecar idle recycling', () {
    late Directory temp;
    late _GateServer gate;
    late _ManualTime time;
    late SpiderHostSupervisor supervisor;
    late LocalSpider gatedSpider;
    late String hostPath;
    final hosts = <SpiderHost>[];

    String extend({bool gateInit = false}) =>
        jsonEncode({'base': gate.base, 'gateInit': gateInit});

    Future<SpiderHost> start({
      LocalSpider? spider,
      bool gateInit = false,
    }) async {
      final local = spider ?? gatedSpider;
      final command = LocalSpiderCommand.resolve(
        spider: local,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: local.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: local.manifest,
        extend: extend(gateInit: gateInit),
      );
      hosts.add(host);
      return host;
    }

    int workDirCount() => Directory(supervisor.workRoot).existsSync()
        ? Directory(supervisor.workRoot)
              .listSync()
              .whereType<Directory>()
              .length
        : 0;

    Future<void> drainIdle(SpiderHost host) async {
      expect(supervisor.hostFor(host.manifest.key), isNull);
      final exit = await host.process.done.timeout(_waitBound);
      expect(exit.expected, isTrue);
      await supervisor.stop(host.manifest.key).timeout(_waitBound);
      expect(host.process.isRunning, isFalse);
      expect(workDirCount(), 0);
    }

    setUp(() async {
      hosts.clear();
      temp = await Directory.systemTemp.createTemp('webhtv-idle-recycle-');
      gate = _GateServer(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      time = _ManualTime();
      supervisor = SpiderHostSupervisor(
        workRoot: p.join(temp.path, 'work'),
        log: LogService(),
        baseBackoff: const Duration(minutes: 1),
        maxBackoff: const Duration(minutes: 4),
        maxFailures: 3,
        idleScheduler: time.schedule,
        clock: () => time.now,
      );
      hostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      );
      final entry = File(p.join(temp.path, 'idle_fixture.py'));
      await entry.writeAsString(_gatedSpiderSource);
      final manifest = SpiderManifest(
        key: 'idle-fixture',
        name: 'Gated real IPC fixture',
        runtime: 'python-3',
        entry: p.basename(entry.path),
        capabilities: const ['home', 'category', 'detail', 'search', 'play'],
        permissions: const SpiderPermissions(network: true),
      );
      final manifestFile = File(p.join(temp.path, 'manifest.json'));
      await manifestFile.writeAsString(jsonEncode(manifest.toJson()));
      gatedSpider = LocalSpider(
        manifest: manifest,
        manifestPath: manifestFile.path,
        rootDir: temp.path,
        entryPath: entry.path,
      );
    });

    tearDown(() async {
      await supervisor.shutdownAll().timeout(_waitBound);
      for (final host in hosts) {
        await host.process.dispose();
      }
      await gate.close();
      await temp.delete(recursive: true);
    });

    test(
      'default deadline exits the real process and removes its work directory',
      () async {
        final host = await start();
        // 挂载的延时必须就是配置的空闲期限，不是别的常量。
        expect(time.delays, [_idleTimeout]);
        time.advance(_idleTimeout - const Duration(milliseconds: 1));
        expect(host.process.isRunning, isTrue);
        expect(supervisor.hostFor(host.manifest.key), same(host));
        expect(workDirCount(), 1);
        time.advance(const Duration(milliseconds: 1));
        await drainIdle(host);
        final status = supervisor.statuses().single;
        expect(status.state, SpiderRuntimeState.stopped);
        expect(status.failureCount, 0);
        expect(status.nextRetryAt, isNull);
      },
    );

    test(
      'parallel starts share one real host and one work directory',
      () async {
        final pair = await Future.wait([start(), start()]);
        expect(pair[0], same(pair[1]));
        expect(workDirCount(), 1);
        await supervisor.stop(pair[0].manifest.key);
        expect(pair.every((host) => !host.process.isRunning), isTrue);
        expect(workDirCount(), 0);
        expect(time.activeCount, 0);
      },
    );

    test(
      'initialization is never reclaimed and gets a full idle deadline',
      () async {
        final starting = start(gateInit: true);
        final request = await gate.take('/initialize');
        time.advance(const Duration(minutes: 20));
        expect(workDirCount(), 1);
        expect(time.activeCount, 0);
        await gate.reply(request, {'ok': true});
        final host = await starting;
        time.advance(_idleTimeout - const Duration(milliseconds: 1));
        expect(host.process.isRunning, isTrue);
        time.advance(const Duration(milliseconds: 1));
        await drainIdle(host);
      },
    );

    test(
      'the last concurrent call completion starts a fresh idle deadline',
      () async {
        final host = await start();
        final first = host.call(SpiderMethod.home, requestId: 'first');
        final firstRequest = await gate.take('/home');
        final second = host.call(SpiderMethod.home, requestId: 'second');
        final secondRequest = await gate.take('/home');
        time.advance(const Duration(minutes: 20));
        expect(host.process.isRunning, isTrue);
        expect(time.activeCount, 0);
        await gate.reply(firstRequest, {'list': [], 'done': 'first'});
        expect((await first as Map)['done'], 'first');
        time.advance(const Duration(minutes: 20));
        expect(host.process.isRunning, isTrue);
        await gate.reply(secondRequest, {'list': [], 'done': 'second'});
        expect((await second as Map)['done'], 'second');
        time.advance(_idleTimeout - const Duration(milliseconds: 1));
        expect(host.process.isRunning, isTrue);
        time.advance(const Duration(milliseconds: 1));
        await drainIdle(host);
      },
    );

    test('cooperative cancellation remains busy until its response and is not a crash', () async {
      final host = await start();
      final pending = host.call(SpiderMethod.home, requestId: 'cancel-me');
      final failure = expectLater(
        pending,
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.cancelled,
          ),
        ),
      );
      final request = await gate.take('/home');
      expect(host.cancel('cancel-me'), isTrue);
      time.advance(const Duration(minutes: 20));
      expect(host.process.isRunning, isTrue);
      await gate.reply(request, {'list': []});
      await failure;
      expect(host.process.isRunning, isTrue);
      expect(supervisor.statuses().single.failureCount, 0);
      time.advance(_idleTimeout);
      await drainIdle(host);
    });

    for (final shutdown in [false, true]) {
      test(
        '${shutdown ? 'shutdownAll' : 'stop'} cancels and drains initialization',
        () async {
          final starting = start(gateInit: true);
          final outcome = starting.then<Object?>(
            (host) => host,
            onError: (Object error) => error,
          );
          final request = await gate.take('/initialize');
          final stopping = shutdown
              ? supervisor.shutdownAll()
              : supervisor.stop(gatedSpider.manifest.key);
          await gate.reply(request, {'ok': true});
          await stopping.timeout(_waitBound);
          expect(
            await outcome,
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.cancelled,
            ),
          );
          expect(supervisor.hostFor(gatedSpider.manifest.key), isNull);
          expect(workDirCount(), 0);
          expect(time.activeCount, 0);
        },
      );
    }

    test(
      'shutdown cancels armed idle deadlines without resurrecting hosts',
      () async {
        final host = await start();
        await supervisor.shutdownAll();
        time.advance(const Duration(minutes: 20));
        expect(host.process.isRunning, isFalse);
        expect(supervisor.statuses(), isEmpty);
        expect(workDirCount(), 0);
        expect(time.activeCount, 0);
      },
    );

    test(
      'bundled Python fixture transparently restarts through the same adapter',
      () async {
        final manifestPath = fixturePath('spider/manifest-fixture.json');
        final manifest = SpiderManifest.fromJson(
          jsonDecode(File(manifestPath).readAsStringSync()),
        );
        final spider = LocalSpider(
          manifest: manifest,
          manifestPath: manifestPath,
          rootDir: p.dirname(manifestPath),
          entryPath: p.join(
            repositoryRoot.path,
            'sidecars',
            'spider-host-python',
            'spiders',
            'fixture_spider.py',
          ),
        );
        final site = Site(
          key: manifest.key,
          name: manifest.name,
          type: 3,
          api: 'spider://fixture',
        );
        final adapter = SidecarRuntime(
          site: site,
          spider: spider,
          command: LocalSpiderCommand.resolve(
            spider: spider,
            hostPath: hostPath,
          )!,
          supervisor: supervisor,
        );
        const target = 'https://media.example/video.m3u8';
        expect(
          (await adapter.play(site, episodeTarget: target)).playUrl,
          target,
        );
        final first = supervisor.hostFor(manifest.key)!;
        hosts.add(first);
        time.advance(_idleTimeout);
        expect(supervisor.hostFor(manifest.key), isNull);
        final secondResult = await adapter.play(site, episodeTarget: target);
        final second = supervisor.hostFor(manifest.key)!;
        hosts.add(second);
        expect(secondResult.playUrl, target);
        expect(second, isNot(same(first)));
        expect(second.process.pid, isNot(first.process.pid));
        expect(first.process.isRunning, isFalse);
        expect((await first.process.done).expected, isTrue);
        expect(workDirCount(), 1);
        await adapter.dispose();
        expect(workDirCount(), 0);
      },
    );

    test(
      'expected idle stops preserve crash count and restart backoff',
      () async {
        final manifestPath = fixturePath('spider/manifest-crash.json');
        final manifest = SpiderManifest.fromJson(
          jsonDecode(File(manifestPath).readAsStringSync()),
        );
        final spider = LocalSpider(
          manifest: manifest,
          manifestPath: manifestPath,
          rootDir: p.dirname(manifestPath),
          entryPath: p.join(
            repositoryRoot.path,
            'sidecars',
            'spider-host-python',
            'spiders',
            'fault_spiders.py',
          ),
        );
        final first = await start(spider: spider);
        time.advance(_idleTimeout);
        await drainIdle(first);
        final second = await start(spider: spider);
        await expectLater(
          second.call(SpiderMethod.home),
          throwsA(
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.crashed,
            ),
          ),
        );
        await second.process.done;
        final status = supervisor.statuses().single;
        expect(status.failureCount, 1);
        expect(status.state, SpiderRuntimeState.backoff);
        expect(status.restartDelay, const Duration(minutes: 1));
        await expectLater(
          start(spider: spider),
          throwsA(
            isA<SpiderError>().having(
              (error) => error.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
        expect(supervisor.statuses().single.failureCount, 1);
      },
    );

    test('declared localProxy hosts stay alive until explicit stop', () async {
      final base = gatedSpider.manifest;
      final manifest = SpiderManifest(
        key: base.key,
        name: base.name,
        runtime: base.runtime,
        entry: base.entry,
        capabilities: base.capabilities.values,
        permissions: const SpiderPermissions(network: true, localProxy: true),
      );
      final host = await start(
        spider: LocalSpider(
          manifest: manifest,
          manifestPath: gatedSpider.manifestPath,
          rootDir: gatedSpider.rootDir,
          entryPath: gatedSpider.entryPath,
        ),
      );
      time.advance(const Duration(minutes: 20));
      expect(host.process.isRunning, isTrue);
      expect(supervisor.hostFor(base.key), same(host));
      await supervisor.stop(base.key);
      expect(host.process.isRunning, isFalse);
      expect(workDirCount(), 0);
    });

    test(
      'returned loopback playback pins an otherwise reclaimable host',
      () async {
        final host = await start();
        const url = 'http://127.0.0.1:19000/stream.m3u8';
        expect(
          (await host.call(SpiderMethod.play, params: const {'id': url})
              as Map)['url'],
          url,
        );
        time.advance(const Duration(minutes: 20));
        expect(host.process.isRunning, isTrue);
        expect(supervisor.hostFor(host.manifest.key), same(host));
        await supervisor.stop(host.manifest.key);
        expect(workDirCount(), 0);
      },
    );
  });
}

const _gatedSpiderSource = r'''
import json
import urllib.request

class Spider:
    def init(self, extend):
        config = json.loads(extend)
        self.base = config['base']
        if config.get('gateInit'):
            self._get('/initialize')
        return {'ok': True}

    def capabilities(self):
        return ['home', 'category', 'detail', 'search', 'play']

    def _get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=10) as response:
            return json.loads(response.read())

    def home(self, params, context):
        result = self._get('/home')
        context.check_cancelled()
        return result

    def category(self, params, context):
        return {'list': []}

    def detail(self, params, context):
        return {'list': []}

    def search(self, params, context):
        return {'list': []}

    def play(self, params, context):
        return {'url': params['id']}

    def destroy(self):
        pass
''';
