@Tags(['external'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/playback_source_context.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/node_runtime.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_proxy_session.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  test('optional extension validates exact IPv4 loopback authority', () {
    SpiderInitResult parse(Object? ext) => SpiderInitResult.fromJson({
      'extensions': {'proxyHttp': ext},
    });
    expect(parse(null).proxyHttp, isNull);
    for (final url in [
      'http://localhost:5555',
      'http://127.0.0.1:0',
      'https://127.0.0.1:5555',
      'http://127.0.0.1:5555/x',
      'http://u@127.0.0.1:5555',
      'http://127.0.0.1:5555?x=1',
    ]) {
      expect(
        parse({'version': 1, 'sessionControl': true, 'baseUrl': url}).proxyHttp,
        isNull,
      );
    }
    expect(
      parse({
        'version': 1,
        'sessionControl': true,
        'baseUrl': 'http://127.0.0.1:5555',
      }).proxyHttp?.baseUrl.port,
      5555,
    );
  });
  final node = NodeRuntimeResolver.resolve();
  if (node == null) {
    test(
      'offline proxy IPC/HTTP fixtures require Node',
      () {},
      skip: 'Node runtime unavailable',
    );
    return;
  }

  late Directory temp;
  late LogService log;
  late SpiderHostSupervisor supervisor;
  late File script;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('proxy-http-dart-');
    log = LogService();
    supervisor = SpiderHostSupervisor(
      workRoot: p.join(temp.path, 'work'),
      log: log,
      debugLog: SpiderDebugLog(log: log, enabled: true),
      idleTimeout: const Duration(milliseconds: 150),
    );
    script = File(p.join(temp.path, 'host.cjs'));
    await script.writeAsString(proxySessionFixtureSource);
  });
  tearDown(() async {
    await supervisor.shutdownAll();
    await temp.delete(recursive: true);
  });
  SidecarRuntime runtime({
    bool authorized = true,
    String runtime = 'jvm',
    String mode = '',
  }) {
    final manifest = SpiderManifest(
      key: 'fixture',
      name: 'fixture',
      runtime: runtime,
      entry: 'host.cjs',
      capabilities: const [
        'home',
        'category',
        'detail',
        'search',
        'play',
        'proxy',
      ],
      permissions: SpiderPermissions(localProxy: authorized),
    );
    final site = Site(
      key: 'fixture',
      name: 'fixture',
      type: 3,
      api: 'csp_Fixture',
      ext: mode,
    );
    return SidecarRuntime(
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
      log: log,
    );
  }

  test('genuine frames open before same generation play; close revokes HTTP and lease', () async {
    final rt = runtime();
    final owner = await rt.prepareProxySession(Object());
    expect(owner, isNotNull);
    final result = await rt.withProxySession(
      owner,
      () => rt.play(rt.site, episodeTarget: 'private-episode-opaque-id'),
    );
    final host = owner!.host;
    expect(supervisor.hostFor('fixture'), same(host));
    expect(host.activePlaybackLeaseCount, 1);
    final url = result.playUrl!;
    expect(owner.ownsUrl(url), isTrue);
    final client = HttpClient();
    Future<int> fetch() async {
      final r = await (await client.getUrl(Uri.parse(url))).close();
      await r.drain<void>();
      return r.statusCode;
    }

    expect(await fetch(), 200);
    expect((await host.call('home') as Map)['ops'], ['session.open', 'play']);
    expect(log.export(), isNot(contains(owner.token)));
    expect(log.export(), isNot(contains('private-episode-opaque-id')));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(host.process.isRunning, isTrue);
    await owner.close();
    expect(host.activePlaybackLeaseCount, 0);
    expect(await fetch(), 403);
    client.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(supervisor.hostFor('fixture'), isNull);
  });
  test('no authorization and JS cannot send session ops even if extension is offered', () async {
    for (final rt in [
      runtime(authorized: false),
      runtime(runtime: 'node-22'),
    ]) {
      expect(await rt.prepareProxySession(Object()), isNull);
      expect(
        (await rt.play(rt.site, episodeTarget: 'opaque')).playUrl,
        'https://example.invalid/legacy.mp4',
      );
      expect(
        (await supervisor.hostFor('fixture')!.call('home') as Map)['ops'],
        ['play'],
      );
      await supervisor.stop('fixture');
    }
  });
  test('old host without extension remains legacy', () async {
    final rt = runtime(mode: 'legacy');
    expect(await rt.prepareProxySession(Object()), isNull);
    expect(
      (await rt.play(rt.site, episodeTarget: 'opaque')).playUrl,
      'https://example.invalid/legacy.mp4',
    );
  });
  test(
    'replace invalidates old owner and stale close cannot revoke new token',
    () async {
      final rt = runtime();
      final first = (await rt.prepareProxySession(Object()))!;
      final next = (await rt.prepareProxySession(Object()))!;
      expect(first.active, isFalse);
      await first.close();
      expect(next.active, isTrue);
      expect(next.host.activePlaybackLeaseCount, 1);
      await next.close();
    },
  );
  test(
    'entry response rejects wrong token, path, authority and releases lease',
    () async {
      for (final mode in ['badToken', 'badPort', 'badPath']) {
        final rt = runtime(mode: mode);
        await expectLater(
          rt.prepareProxySession(Object()),
          throwsA(isA<StateError>()),
        );
        expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 0);
        await supervisor.stop('fixture');
      }
    },
  );
  test(
    'renew failure and process loss invalidate owner without respawning',
    () async {
      final rt = runtime(mode: 'renewFail');
      final owner = (await rt.prepareProxySession(Object()))!;
      await owner.renew();
      expect(owner.active, isFalse);
      expect(owner.host.activePlaybackLeaseCount, 0);
      final fresh = (await rt.prepareProxySession(Object()))!;
      await supervisor.stop('fixture');
      await Future<void>.delayed(Duration.zero);
      expect(fresh.active, isFalse);
      expect(fresh.host.activePlaybackLeaseCount, 0);
      expect(supervisor.hostFor('fixture'), isNull);
    },
  );
  test('App serviceOverride keeps new owner, logs no token and revoke cleans JVM without /p', () async {
    final rt = runtime();
    final router = _RuntimeRouter(rt);
    final service = SiteService(
      appConfig: AppConfig(sites: [rt.site]),
      router: router,
    );
    final app = _ContextState(
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
    try {
      final decision = (await app.resolvePlayback(
        episodeTarget: 'opaque',
        siteOverride: rt.site,
        serviceOverride: service,
      ))!;
      final token = Uri.parse(decision.url!).pathSegments[1];
      expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 1);
      expect(log.export(), isNot(contains(token)));
      expect(
        await app.resolvePlayback(
          episodeTarget: 'already stale',
          siteOverride: rt.site,
          serviceOverride: service,
          isCurrent: () => false,
        ),
        isNull,
      );
      expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 1);
      app.revokeProxySession();
      expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 0);
    } finally {
      app.dispose();
      router.dispose();
    }
  });
  test(
    'App original-source context uses own router and dispose revokes exact JVM',
    () async {
      final rt = runtime();
      final router = _RuntimeRouter(rt);
      final config = AppConfig(sites: [rt.site]);
      final service = SiteService(appConfig: config, router: router);
      final app = _ContextState(
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
      app.context = PlaybackSourceContext(
        sourceKey: 'original',
        record: ConfigRecord(
          id: 1,
          name: 'original',
          origin: 'fixture',
          updatedAt: DateTime(2026),
          siteCount: 1,
          liveCount: 0,
        ),
        config: config,
        service: service,
      );
      final decision = await app.resolvePlaybackForSource(
        sourceKey: 'original',
        siteKey: 'fixture',
        episodeTarget: 'opaque',
      );
      expect(decision?.url, contains('/s/'));
      expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 1);
      app.dispose();
      expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 0);
      router.dispose();
    },
  );

  test(
    'stale app response closes only its captured owner, not newer playback',
    () async {
      final rt = runtime();
      final router = _RuntimeRouter(rt);
      final service = _GatedService(
        appConfig: AppConfig(sites: [rt.site]),
        router: router,
      );
      final app = _ContextState(
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
      try {
        final first = app.resolvePlayback(
          episodeTarget: 'first',
          siteOverride: rt.site,
          serviceOverride: service,
        );
        final old = await service.firstReturned.future;
        final next = (await app.resolvePlayback(
          episodeTarget: 'second',
          siteOverride: rt.site,
          serviceOverride: service,
        ))!;
        service.release.complete();
        expect(await first, isNull);
        expect(old.url, isNot(next.url));
        expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 1);
        final client = HttpClient();
        final response = await (await client.getUrl(Uri.parse(next.url!)))
            .close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        client.close(force: true);
        await app.stopProxy();
        expect(supervisor.hostFor('fixture')!.activePlaybackLeaseCount, 0);
      } finally {
        if (!service.release.isCompleted) service.release.complete();
        app.dispose();
        router.dispose();
      }
    },
  );
  test(
    'old generation close cannot touch a new config runtime with same site key',
    () async {
      final rt = runtime();
      final first = (await rt.prepareProxySession(Object()))!;
      final other = runtime();
      final next = (await other.prepareProxySession(Object()))!;
      expect(identical(first.host, next.host), false);
      expect(first.active, false);
      await first.close();
      expect(next.active, true);
      expect(next.host.activePlaybackLeaseCount, 1);
      await next.close();
    },
  );
  test(
    'legacy /p authorization remains live until replacement decision succeeds',
    () async {
      final rt = runtime(mode: 'legacy');
      final router = _RuntimeRouter(rt);
      final service = _GatedService(
        appConfig: AppConfig(sites: [rt.site]),
        router: router,
      );
      final app = _ContextState(
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
      try {
        await app.proxyDecision(
          PlaybackDecision(
            action: PlaybackAction.direct,
            url: 'https://cdn.example/old.mp4',
            headers: HeaderMap({'Referer': 'https://example.com/'}),
          ),
          siteKey: 'old',
        );
        final previous = app.proxySessionFingerprint;
        expect(previous, isNotNull);
        final pending = app.resolvePlayback(
          episodeTarget: 'new',
          siteOverride: rt.site,
          serviceOverride: service,
        );
        await service.firstReturned.future;
        expect(app.proxySessionFingerprint, previous);
        service.release.complete();
        await pending;
        expect(app.proxySessionFingerprint, isNull);
        await app.stopProxy();
      } finally {
        if (!service.release.isCompleted) service.release.complete();
        app.dispose();
        router.dispose();
      }
    },
  );

  test(
    'concurrent config runtimes cannot share a negotiated generation',
    () async {
      final a = runtime();
      final b = runtime(mode: 'other-config');
      final contexts = [Object(), Object()];
      final results = await Future.wait([
        a
            .prepareProxySession(contexts[0])
            .then<Object?>((x) => x)
            .catchError((Object e) => e),
        b
            .prepareProxySession(contexts[1])
            .then<Object?>((x) => x)
            .catchError((Object e) => e),
      ]);
      final owners = results.whereType<SpiderProxySession>().toList();
      if (owners.length == 2) {
        expect(identical(owners[0].host, owners[1].host), false);
      }
      for (final owner in owners) {
        if (owner.active) {
          expect(identical(supervisor.hostFor('fixture'), owner.host), true);
        }
        await owner.close();
      }
      expect(owners, isNotEmpty);
    },
  );

  test(
    'source play failure closes session and releases generation lease',
    () async {
      final rt = runtime(mode: 'playFail');
      final owner = (await rt.prepareProxySession(Object()))!;
      await expectLater(
        rt.withProxySession(
          owner,
          () => rt.play(rt.site, episodeTarget: 'opaque'),
        ),
        throwsA(anything),
      );
      expect(owner.active, false);
      expect(owner.host.activePlaybackLeaseCount, 0);
      expect((await owner.host.call('home') as Map)['ops'], [
        'session.open',
        'play',
        'session.close',
      ]);
    },
  );

  test(
    'session open rejection preserves safe code category and diagnostic ID',
    () async {
      final rt = runtime(mode: 'openReject');
      await expectLater(
        rt.prepareProxySession(Object()),
        throwsA(
          isA<SpiderError>()
              .having((e) => e.code, 'code', 'SPIDER_BAD_REQUEST')
              .having((e) => e.category, 'category', 'protocol')
              .having((e) => e.diagnosticId, 'diagnostic', 'diag-open-rejected')
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('raw=secret')),
              ),
        ),
      );
      expect(log.export(), contains('SPIDER_BAD_REQUEST'));
      expect(log.export(), isNot(contains('raw=secret')));
      final router = _RuntimeRouter(rt);
      final service = SiteService(appConfig: AppConfig(sites: [rt.site]), router: router);
      final app = _ContextState(paths: AppPaths.resolve(overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'state'),
      }), log: log);
      try {
        await expectLater(app.resolvePlayback(episodeTarget: 'opaque', siteOverride: rt.site,
          serviceOverride: service), throwsA(isA<SpiderError>()));
        expect(log.export(), contains('diag-open-rejected'));
        expect(log.export(), contains('SPIDER_BAD_REQUEST'));
        expect(log.export(), isNot(contains('raw=secret')));
      } finally { app.dispose(); router.dispose(); }

    },
  );
  test(
    'source error echo cannot expose scoped token in debug or App logs',
    () async {
      final rt = runtime(mode: 'playEcho');
      final owner = (await rt.prepareProxySession(Object()))!;
      await expectLater(
        rt.withProxySession(
          owner,
          () => rt.play(rt.site, episodeTarget: 'opaque'),
        ),
        throwsA(anything),
      );
      expect(log.export(), contains('SPIDER_PARSE_ERROR'));
      expect(log.export(), isNot(contains(owner.token)));
      final router = _RuntimeRouter(rt);
      final service = SiteService(
        appConfig: AppConfig(sites: [rt.site]),
        router: router,
      );
      final app = _ContextState(
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
      try {
        await expectLater(
          app.resolvePlayback(
            episodeTarget: 'opaque',
            siteOverride: rt.site,
            serviceOverride: service,
          ),
          throwsA(anything),
        );
        expect(
          log.export(),
          isNot(matches(RegExp(r'/s/[A-Za-z0-9_-]{32,}/proxy'))),
        );
        expect(log.export(), isNot(contains('opaque=secret')));
      } finally {
        app.dispose();
        router.dispose();
      }
    },
  );

  test(
    'fallback rewrite is exact own proxy route and preserves raw query',
    () async {
      final rt = runtime();
      final owner = (await rt.prepareProxySession(Object()))!;
      final base = owner.host.initResult!.proxyHttp!.baseUrl;
      const query = 'a=%2f%2B&sig=x+y&x=%252F';
      expect(owner.scopeUrl('$base/proxy?$query'), '${owner.entryUrl}?$query');
      expect(owner.scopeUrl('$base/chunk?$query'), '$base/chunk?$query');
      expect(
        owner.scopeUrl('http://127.0.0.1:9978/proxy?$query'),
        'http://127.0.0.1:9978/proxy?$query',
      );
      await owner.close();
      expect(owner.ownsUrl(owner.entryUrl.toString()), isFalse);
    },
  );
}

const proxySessionFixtureSource = r'''
const http=require('http');let buf=Buffer.alloc(0),session=null,ops=[],mode='';
const server=http.createServer((req,res)=>{res.statusCode=session&&req.url.startsWith('/s/'+session.token+'/proxy')?200:403;res.end('fixture');});
function send(id,result,error){const body=Buffer.from(JSON.stringify({jsonrpc:'2.0',id,...(error?{error:typeof error==='object'?error:{code:'SPIDER_INTERNAL',message:'fixture failure'}}:{result})}));const h=Buffer.from('Content-Length: '+body.length+'\r\n\r\n');process.stdout.write(Buffer.concat([h,body]));}
async function handle(m){const p=m.params||{};if(m.method==='initialize'){mode=p.extend;await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port;send(m.id,{abi:'webhtv-ipc-v1',capabilities:['home','category','detail','search','play','proxy'],...(mode==='legacy'?{}:{extensions:{proxyHttp:{version:1,sessionControl:true,baseUrl:base}}})});}
else if(m.method==='proxy'){ops.push(p.op);if(p.op==='session.open'){session=p;if(mode==='openReject'){send(m.id,null,{code:'SPIDER_BAD_REQUEST',category:'protocol',message:'open denied token='+p.token+'?raw=secret',diagnosticId:'diag-open-rejected'});return;}let entry='http://127.0.0.1:'+server.address().port+'/s/'+p.token+'/proxy';if(mode==='badToken')entry=entry.replace(p.token,'wrong');if(mode==='badPort')entry=entry.replace(':'+server.address().port,':1');if(mode==='badPath')entry+='/other';send(m.id,{sessionId:p.sessionId,entryUrl:entry,expiresInMs:120000});}else if(p.op==='session.close'){if(session?.sessionId===p.sessionId)session=null;send(m.id,{sessionId:p.sessionId,closed:true});}else if(mode==='renewFail')send(m.id,null,true);else send(m.id,{sessionId:p.sessionId,expiresInMs:120000});}
else if(m.method==='play'){ops.push('play');if(mode==='playFail'){send(m.id,null,true);return;}if(mode==='playEcho'){send(m.id,null,{code:'SPIDER_PARSE_ERROR',category:'site',message:'source failed http://127.0.0.1:'+server.address().port+'/s/'+session.token+'/proxy?opaque=secret',diagnosticId:'diag-play-echo'});return;}send(m.id,{url:session?'http://127.0.0.1:'+server.address().port+'/s/'+session.token+'/proxy?action=media':'https://example.invalid/legacy.mp4',parse:0});}
else if(m.method==='home')send(m.id,{ops});else if(m.method==='destroy'){session=null;send(m.id,{});server.close();process.stdin.destroy();}else send(m.id,{});}
process.stdin.on('data',b=>{buf=Buffer.concat([buf,b]);while(true){const end=buf.indexOf('\r\n\r\n');if(end<0)break;const n=Number(/Content-Length: (\d+)/i.exec(buf.subarray(0,end).toString())[1]);if(buf.length<end+4+n)break;const m=JSON.parse(buf.subarray(end+4,end+4+n));buf=buf.subarray(end+4+n);handle(m).catch(()=>send(m.id,null,true));}});
process.stdin.on('end',()=>{server.close();process.exit(0);});
''';

class _RuntimeRouter extends SpiderRouter {
  _RuntimeRouter(this.runtime)
    : super(client: HttpApiClient(), globalHeaders: const []);
  final SidecarRuntime runtime;
  @override
  SiteRuntime runtimeFor(Site site) => runtime;
}

class _ContextState extends AppState {
  _ContextState({required super.paths, required super.log});
  PlaybackSourceContext? context;
  @override
  PlaybackSourceContext? playbackContextFor(String key) => context;
}

class _GatedService extends SiteService {
  _GatedService({required super.appConfig, required super.router});
  final firstReturned = Completer<PlaybackDecision>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<SiteCallResult<PlaybackDecision>> resolvePlayback({
    required Site site,
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    dynamic parseService,
    dynamic parseFailover,
    String? preferredParseName,
  }) async {
    final first = ++calls == 1;
    final result = await super.resolvePlayback(
      site: site,
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      qualityIndex: qualityIndex,
      preferredParseName: preferredParseName,
    );
    if (first) {
      firstReturned.complete(result.value);
      await release.future;
    }
    return result;
  }
}
