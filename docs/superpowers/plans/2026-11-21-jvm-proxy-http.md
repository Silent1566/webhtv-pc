# JVM proxy HTTP Implementation Plan

> For agentic workers: use subagent-driven-development for the following isolated boundaries. The lead owns integration review, no commits unless the user requests them.

**Goal:** Turn the verified Wex loopback/proxy result into an authenticated, bounded streaming endpoint and preserve playback/session lifecycle.
**Architecture:** Per-sidecar-generation JDK HTTP data plane on 127.0.0.1 port0; existing IPC carries only negotiated session control. Dart owner holds exact host/service context and a renewable/releasable lease. No global currentSite, JSON media, global idle disable, or bypass of ordinary proxy policy.
**Tech stack:** Existing Dart/Flutter IPC and proxy policy utilities; JDK17+ HttpServer and standard streams; no new dependencies.
**Spec/approval:** User selected complete_bridge after successful90s+diagnosis round. Research: .probe/proxy-bridge/contract-research.md (source paths and artifact offsets). This plan is the authoritative frozen contract.

## Global constraints and settled decisions
- Preserve play90s, other method budgets, IPC response/frame/lifetime-stdout guards, process isolation and legacy JS/Python proxy behavior.
- Explicit localProxy authorization AND proxy capability; enable narrowly for app-generated unpacked-shell installations evidenced by probe.shellPayload + installed/unpacked record and payload.jar. Log migration, do not turn arbitrary manual manifests false into true.
- Single active session per sidecar, new open invalidates previous token/streams; exact Dart host object is generation identity. Old-generation close/renew cannot affect a new process. No user-data mutation in test probes.
- GET/HEAD, 127.0.0.1 only; reject browser Origin and invalid Host, wrong/missing token, non-health unscoped requests, ambiguous query duplicate values/CRLF. Health check action only returns body exactly ok while ready. No wildcard CORS/file routes/general URL forwarder.
- Stream in bounded64KiB buffers with backpressure and finally-close. Preserve200/206/416 and trusted response headers (Content-Type, Length, Range, Accept-Ranges, Encoding, Cache-Control, ETag, Last-Modified; Location only if safely validated); strip hop-by-hop/Set-Cookie. Never use InputStream.available as length, readAllBytes, whole-media Base64. No invented Range support.
- Owner renew every30s, session TTL120s. HTTP active reads validated against session expiration and revoked on close; close/serverstop/disconnect must close source streams. No long-lived owner after explicit playback stop/config change/stale response/appdispose.
- Diagnostic logs must not reveal session token/raw query/headers/episode opaque IDs. Existing debug snapshots must not newly expose control tokens or tokenized URL path.

## Frozen wire contract
Initialize result adds optional extensions (only advertise after authorized server has bound and a genuine router exists):
{"extensions":{"proxyHttp":{"version":1,"baseUrl":"http://127.0.0.1:<ephemeral-port>","sessionControl":true}}}
Retain abi webhtv-ipc-v1 and existing major/minor; capability proxy advertised only for the authorized supported adapter.

method proxy, params {op:session.open,sessionId:<unique>,token:<high-entropy>,ttlMs:120000}
 -> {sessionId:<same>,entryUrl:http://127.0.0.1:<same-port>/s/<token>/proxy,expiresInMs:120000}
method proxy, params {op:session.renew,sessionId:<same>,ttlMs:120000}
 -> {sessionId:<same>,expiresInMs:120000}
method proxy, params {op:session.close,sessionId:<same>}
 -> {sessionId:<same>,closed:true}
Unknown/stale renew fails; close idempotent. Control is IPC only, no HTTP session creation. Legacy params.param unchanged. Dart validates negotiated and returned authority/path/token, not arbitrary host URLs.
HTTP GET/HEAD /s/<token>/proxy?<original-source-query>; unscoped /proxy check action may answer ok, unscoped business requests forbidden. If payload generates chunk URLs, preserve scope through host getUrl(boolean); don't globally rewrite arbitrary loopback routes or normalize signed rawquery twice.

## JVM boundary and task A (run0/3)
Files permitted: src/webhtv/spider/{Spider.java,SidecarServer.java,CatVodSpiderAdapter.java,SpiderProxyHttpServer.java(new)}, src-android-shim/src/com/github/catvod/{Proxy.java(new),spider/DexNative.java}, build.ps1, host.jar, test/ProxyHttpContractTest.java(new). Prefix sidecars/spider-host-jvm/ for every path.
- [ ] RED native fixture: authorized negotiated extension, session.open, exact health body, token denial/expiry/close, fourth headers, Range206/416/HEAD, streaming>64MiB keeps IPC usable, disconnect releases InputStream.
- [ ] Implement typed in-process Object[]->status/MIME/InputStream/headers adapter and bounded HTTP endpoint; SidecarServer proxies small session ops, closes server with spider lifecycle. Don't route media through JSON.
- [ ] Implement host com.github.catvod.Proxy getPort/getUrl(boolean) ABI. After payload loader is ready explicitly attach ProxyOrigin.init without calling InitOrigin.init/native. Route payload ProxyOrigin.proxy via its own loader, verified direct-spider fallback only on absence, not on invocation errors; avoid shell recursive Proxy.
- [ ] Verify native fixtures and offline build; final host.jar once. No Flutter tests here while B runs.

## Dart boundary and task B (run0/3)
Files permitted: apps/desktop-flutter/lib/core/ipc_protocol.dart; lib/services/{spider_process.dart,sidecar_runtime.dart,spider_router.dart,jar_intake.dart,csp_jar_probe.dart,spider_proxy_session.dart(new)}; lib/state/app_state.dart; test/{spider_proxy_session_test.dart(new),sidecar_idle_recycle_test.dart,jar_intake_test.dart}. Prefix apps/desktop-flutter/ where absent.
- [ ] RED fake sidecar/HTTP fixture: parse opt-in extension, no media inIPC, actual play ownership and explicit authorization, same host open/play, stale response close exact owner, renew failures release, stop/config/dispose invalidate URLs, legacy unchanged.
- [ ] Use narrow generated-shell launch-manifest migration before process command construction; synthetic LocalSpider must reflect actual launch caps/permissions instead of cached defaultfalse. Ordinary manual manifests untouched.
- [ ] Add typed session control owner and high-entropy token. Call/open before play in actual serviceOverride context, renew30s/ttl120s, cleanup synchronous invalidation plus async IPCclose; explicit generation identity guards.
- [ ] Lease hooks in supervisor: only negotiated proxyHttp hosts replace permanent loopback/localProxy pin with actual bounded leases; legacy rules remain. Last lease release restarts idle timer. Process exit/force stop clears leases.
- [ ] App integrates stop/revoke/config disposal and stale selection safely; active stream URLs bypass only the existing arbitrary outbound /p proxy path as already-authenticated own endpoint, not broad loopback allowlisting. Do not edit proxy_server.dart; the JVM owns its data plane.
- [ ] Test offline own fixtures and analyze touched Dart files. No unrelated refactoring/global process kills; report precise changed paths and incremental patch.

## Integration / acceptance (Lead, run0/3)
- [ ] Review final incremental diffs and every criterion above, build host, full analyze and risk suites (retry/IPC/idle/JVM/proxy/session/intake).
- [ ] Bounded real probe from copied cached Wex site: initialize authorized manifest -> session.open -> real detail full first id -> play. Prove source returns scoped endpoint without scan fallback, call health, fetch playlist and at least one actual media segment/finite range; record status/MIME/byte count only. At most3 real play calls and6 media fetches total for this acceptance (one extra call is the sole retry after the lead test harness accidentally intercepted HTTP; not an upstream failure or unbounded retry), no persistent downloaded movie.
- [ ] Verify session.close rejects saved endpoint; generation expiry/restart and simultaneous different-site fixtures cannot cross-route. Isolated fullstream fixture exceeds64MiB yet IPC counters remain healthy and body memory stays bounded.
- [ ] Correct misleading fixed9978 statements and ADR proxy unsupported boundary for this new extension; document lack of universal Android/native compatibility honestly.
- [ ] No claim of playable video until actual media evidence; if upstream environmental restriction prevents it, report not accepted and route scope through ask_user_question.
