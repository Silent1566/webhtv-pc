@Tags(['external'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/node_runtime.dart';
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
    final extraProcesses = <SidecarProcess>[];

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
      extraProcesses.clear();
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
      for (final process in extraProcesses) {
        await process.dispose();
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

    test('negotiated JVM leases renew, release and expire into a fresh idle deadline', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) { markTestSkipped('Node runtime unavailable for negotiated JVM fixture'); return; }
      final entry=File(p.join(temp.path,'lease-host.cjs'));await entry.writeAsString(_leaseHostSource);
      final manifest=SpiderManifest(key:'lease-fixture',name:'lease-fixture',runtime:'jvm',entry:'lease-host.cjs',capabilities:const ['home','category','detail','search','play','proxy'],permissions:const SpiderPermissions(localProxy:true));
      final host=await supervisor.ensureRunning(siteKey:manifest.key,executable:node.executable,arguments:[...node.arguments,entry.path],manifest:manifest);
      hosts.add(host);
      final lease=host.acquirePlaybackLease('session-1');
      time.advance(const Duration(seconds:100));expect(host.process.isRunning,true);
      lease.renew(const Duration(seconds:120));
      time.advance(const Duration(seconds:119));expect(host.activePlaybackLeaseCount,1);
      lease.release();lease.release();expect(host.activePlaybackLeaseCount,0);
      time.advance(_idleTimeout-const Duration(milliseconds:1));expect(host.process.isRunning,true);
      final abandoned=host.acquirePlaybackLease('abandoned');
      time.advance(const Duration(seconds:120));expect(abandoned.active,false);expect(host.activePlaybackLeaseCount,0);
      time.advance(_idleTimeout-const Duration(milliseconds:1));expect(host.process.isRunning,true);
      time.advance(const Duration(milliseconds:1));await drainIdle(host);
    });

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

    // -----------------------------------------------------------------------
    // 超时兜底终止（§9.3.1「超时后依次执行取消、宽限等待、终止进程树」）
    //
    // 宽限期只该判「这一个请求慢」，不该判「整站挂死」：还有别的调用方在途时
    // 终止进程等于替别人做决定，一次慢请求就能让整站下线。
    // -----------------------------------------------------------------------
    group('超时兜底终止守卫', () {
      // 一个真实但「死也不说话」的子进程：读过 stdin，永不写帧，也不认取消。
      //
      // 只有完全无响应的进程才该走到终止那一步；用 /bin/sh + sleep 造它，
      // 判定就与站源是否配合取消无关。
      Future<SidecarProcess> startHungProcess() async {
        final workDir = p.join(temp.path, 'hung', 'site');
        final process = await SidecarProcess.start(
          SidecarLaunchSpec(
            siteKey: 'hung-fixture',
            executable: '/bin/sh',
            arguments: const ['-c', 'exec sleep 60'],
            workingDirectory: workDir,
            logFile: p.join(workDir, 'stderr.log'),
          ),
        );
        extraProcesses.add(process);
        return process;
      }

      test('并发请求中一次超时不误杀进程', () async {
        final host = await start();
        final slow = host.call(
          SpiderMethod.home,
          requestId: 'slow',
          deadline: const Duration(milliseconds: 200),
        );
        final slowFailure = expectLater(
          slow,
          throwsA(
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.timeout,
            ),
          ),
        );
        // 两条 HTTP 连接同时被扣住 = 两个请求真的并发在同一个 sidecar 里在途。
        final slowHttp = await gate.take('/home');
        final fast = host.call(
          SpiderMethod.home,
          requestId: 'fast',
          deadline: const Duration(seconds: 30),
        );
        final fastHttp = await gate.take('/home');
        await slowFailure;
        // 守住原 500ms 窗口：守卫到点时 fast 仍被扣在 gate 上。
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(host.process.isRunning, isTrue, reason: '一次慢请求不得杀掉整站进程');
        expect(host.process.killTreeCount, 0);
        expect(supervisor.statuses().single.failureCount, 0);
        for (final request in [slowHttp, fastHttp]) {
          await gate.reply(request, {'list': [], 'done': 'pong'});
        }
        final result = await fast as Map;
        expect(result['done'], 'pong', reason: '另一个在途请求必须照常成功');
        expect(result['list'], isEmpty);
        expect(host.process.isRunning, isTrue);
      });

      test('仍有其它在途请求时守卫只放弃这一刀', () async {
        if (Platform.isWindows) return;
        final process = await startHungProcess();
        final timedOut = expectLater(
          process.request(
            SpiderMethod.home,
            const {},
            deadline: const Duration(milliseconds: 200),
          ),
          throwsA(
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.timeout,
            ),
          ),
        );
        // 第二个请求同样没有响应，但它让 `_pending` 一直非空：这不代表进程挂死。
        final stillInFlight = expectLater(
          process.request(
            SpiderMethod.search,
            const {},
            deadline: const Duration(seconds: 30),
          ),
          throwsA(isA<SpiderError>()),
        );
        await timedOut;
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(process.killGuardArmed, isFalse, reason: '守卫到期后应当放弃这一刀');
        expect(process.killTreeCount, 0, reason: '还有调用方在途时不得终止进程');
        expect(process.isRunning, isTrue);
        await process.dispose();
        await stillInFlight;
      });

      test('dispose 之后宽限期守卫不再补刀', () async {
        if (Platform.isWindows) return;
        final process = await startHungProcess();
        await expectLater(
          process.request(
            SpiderMethod.home,
            const {},
            deadline: const Duration(milliseconds: 200),
          ),
          throwsA(
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.timeout,
            ),
          ),
        );
        expect(process.killGuardArmed, isTrue, reason: '超时后必须挂上宽限守卫');
        await process.dispose();
        expect(process.killGuardArmed, isFalse, reason: 'dispose 必须撤销守卫');
        final kills = process.killTreeCount;
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(
          process.killTreeCount,
          kills,
          reason: '守卫若无句柄，会在 dispose 之后照样补一刀',
        );
        expect(process.killGuardArmed, isFalse);
        expect(process.isRunning, isFalse);
      });

      test('真正挂死的进程仍会在宽限期后终止', () async {
        if (Platform.isWindows) return;
        final process = await startHungProcess();
        await expectLater(
          process.request(
            SpiderMethod.home,
            const {},
            deadline: const Duration(milliseconds: 200),
          ),
          throwsA(
            isA<SpiderError>().having(
              (error) => error.code,
              'code',
              SpiderErrorCode.timeout,
            ),
          ),
        );
        expect(process.killGuardArmed, isTrue);
        // 没有其它在途请求：宽限期一过必须补刀，进程树终止要能到达。
        final exit = await process.done.timeout(_waitBound);
        expect(exit.expected, isTrue, reason: '终止由超时守卫发起，属于预期停机');
        expect(process.isRunning, isFalse);
        expect(process.killTreeCount, 1);
      });
    });
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

const _leaseHostSource=r'''
let buf=Buffer.alloc(0);
function send(id,result){const b=Buffer.from(JSON.stringify({jsonrpc:'2.0',id,result}));process.stdout.write(Buffer.concat([Buffer.from('Content-Length: '+b.length+'\r\n\r\n'),b]));}
process.stdin.on('data',data=>{buf=Buffer.concat([buf,data]);while(true){const e=buf.indexOf('\r\n\r\n');if(e<0)break;const n=Number(/Content-Length: (\d+)/i.exec(buf.subarray(0,e).toString())[1]);if(buf.length<e+4+n)break;const m=JSON.parse(buf.subarray(e+4,e+4+n));buf=buf.subarray(e+4+n);send(m.id,m.method==='initialize'?{abi:'webhtv-ipc-v1',capabilities:['home','category','detail','search','play','proxy'],extensions:{proxyHttp:{version:1,sessionControl:true,baseUrl:'http://127.0.0.1:19000'}}}:{});if(m.method==='destroy')process.exit(0);}});
''';
