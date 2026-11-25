# Desktop real-source baseline — 2026-11-24

**Status: ready (evidence complete; strict uplift gate unverified). Run1/3.** No Android runtime or production code implemented.

## Provenance and inventory

SQLite schema inspected first, connection mode=ro:23 configs /937 site bindings. Active PC config25 intersects4 Android T3 keys. Config22 intersects203 keys (119 T3,84 T4). Across PC configs the union intersection is **203/204** Android exports. Store: $HOME/.local/share/webhtv-pc/webhtv-pc.sqlite3; caches: $HOME/.config/webhtv-pc/spiders (183 csp directories,118 direct,13 local,140 manifests,25 JARs/15 unique SHA256s). No history/account records exported.

Read-only installed-app run-as succeeds. Android Path.java:53–58,86–88 derives internal cache/jar; actual listing found four JARs. JarLoader.java:185–201,225–244 maps URL MD5/cache and initializes ext. Four observed files were copied before probes; after-run SHA256 matches every copy. PC cache matches49daf (old ordinary) and83667 (native), **not current ordinaryfae799**. Full artifact SHA256s/entries are in JSON.

**Binary equality and config equality are separate.** Fetched original source has119 T3 bindings:118 usefae799, one native Danmaku uses83667. PC22 candidate API/JAR descriptors match fetched metadata but AList/Media/BiliBili ext differs. Effective204-site export hides original API/ext. Fetched config attribution does not prove installed in-memory ext. Desktop business uses exact pulledfae799 + fetched serialized ext: **conditional fetched-snapshot baseline, never strict installed same-input uplift**. Candidate ext is a credential-bearing remote-forward envelope. Data proves wrapper/current input works, not local native scraper reuse; raw ext/URLs/config remain ignored.

## Actual support and outcomes

| Input | Existing classifier / intake | Dynamic outcome |
|---|---|---|
| Currentfae799 ordinary | translatableDex;1228 classes,4 repairs,0 stubs; CLI3181ms | AList/BiliBili wrapper data; Media UI load fails |
| Old49daf ordinary | translatableDex;1227 classes,4 repairs,0 stubs; CLI3576ms | selfcheck only; not current-source business comparison |
| Native83667 / leo弹幕 (DanmakuSpider) | dex + ARM32/64 libgoproxy.so; nativeLibrary | actual JarIntake.install refusal50ms,ok=false,target not created; no bypass |
| Nativede84 / libjsc | dex + ARM32/64,x86/64 libraries; nativeLibrary | install refusal17ms,target not created; custom registry maps wv_yszb/csp_WvSpider; UI runtime not tested |
| PC shell620afe… | wex libs + .guard; shellGuard | direct install refusal1ms,target not created; no unpack/run/Android shell comparison |

Shell is not universally unsupported: csp_jar_probe.dart:17–29 and spider_router.dart:697–725 support prepared payload/entry chains. That path was not bypassed or tested.

### Current source, existing JVM IPC

| Case | Initial home/category/homeVod | Peer-aligned category/detail/search/play |
|---|---|---|
| AList |15 classes/103ms;20 items/59ms;60 items/636ms (init1196ms) |20/38ms;1/123ms;60/6205ms;18ms **empty URL; folder/no valid playable leaf sampled** |
| BiliBili |31 classes/429ms;28 items/612ms;28 items/425ms (init407ms) |29/429ms;1/333ms;110/1303ms;221ms **URL nonempty; media untested** |
| Media |host exit3 after181ms,initialize EOF |no business: missing android/widget/LinearLayout during EntryLoader declared-method resolution; NoClassDefFoundError→IllegalArgumentException |

Aligned category/detail/search/play inputs come from peer's recorded request query parameters, not guessed IDs. Warm count variation is observed data, not proof of config isolation/equality. Each ordinary archive's class-load selfcheck has5 failures: WebViewClient, DialogInterface.OnKeyListener and QuickJS JSCallFunction/MapCreator. Selfcheck initializes no class and executes no business. JSON records frame digests, request/response bytes,counts,deadlines,timings; raw IDs/media URLs are omitted.

## Commands, limits, preservation

All ADB: $ADB -P5038 -s192.168.50.3:5555; only pwd/ls,exec-out run-as cat,and post-run sha256sum. **Zero Android business HTTP calls** by this worker. No app launch/UI/root/settings/forward/server actions. Lead's separately added guest5000 media forward is owned/validated elsewhere; a guest-loopback address is not desktop-reachable by spelling alone.

Private rerunnable scripts: .superpowers/sdd/2026-11-24-android-runtime-validation/desktop/inspect.dart (unchanged production classifier),refusal.dart (unchanged install API;3 refusal assertions passed),ipc_probe.py and ipc_followup.py (existing Content-Length JSON-RPC). They write only scratch manifests/context/translated bundles.

Translation command: java -Xmx256m -Xms16m -Duser.home=$SCRATCH -Djava.io.tmpdir=$SCRATCH/tmp -cp "$HOST:$LIB/*" webhtv.spider.DexIntakeCli --site $SCRATCH/dex-<md5> --archive $SCRATCH/android-jars/<md5>.jar --selfcheck. Both CLI exit0. JAVA_TOOL_OPTIONS applies256MiB heap and scratch temporary path to selfcheck child too. JDK21.0.10,unchanged prebuilt host.jar. Dart: $WORKSPACE/.local/linux-build/flutter/bin/cache/dart-sdk/bin/dart --packages=apps/desktop-flutter/.dart_tool/package_config.json $SCRATCH/<script>.dart. Sanitized command-template fingerprints and actual frame fingerprints in JSON; exact raw argv captured in scratch translations/business JSON.

Existing jar_intake_test.dart and csp_jar_probe_test.dart suites **not run**; no full-suite pass claim. Actual classifier/install APIs,CLI/IPC and3 real-source refusal assertions are executed checks.

5 distinct real artifacts,3 business entries. Heap256MiB/process,25s/call,8MiB frame bound. Current ordinary translation + five initial/followup process cases17044ms,below180s source cap.

Preservation: every PC config column before/after equal; all25 live PC JAR hashes unchanged; all4 Android cache hashes unchanged. Production git diff empty before evidence writes. No worker user config/cache/APK/accounts changes,no production edits,commits or push. Only these two evidence files outside ignored scratch. Lead-owned forward35829/server5038 untouched.

## Unverified gates

Installed ext/config equality,Android native execution attribution,shell/UI universal coverage,desktop media reachability and decode/render remain unverified. AList empty URL is not playback; Bili URL is not playback. Native refusal is a real desktop boundary,not Android uplift evidence. Cold/recovery start,cancellation/reconnect,concurrency/config isolation,throughput/CPU and playback decoding not tested. Android peer owns Android/media evidence. **No universal compatibility or milestone gate-pass claim.**

### Final custom-source provenance check

Read-only Android custom-registry snapshot maps wv_yszb/csp_WvSpider to de84 cached JAR. Static DEX string table contains the exact WvSpider descriptor and archive-scoped WebView/WebViewClient/WebChromeClient/Activity/LinearLayout types. These archive references do not prove every Wv call executes UI. Existing nativeLibrary refusal was retained; no translation/native bypass or Android business/UI action. Full sanitized native-entry SHA256s are in JSON. Installed custom ext equality remains unverified.

AList semantics clarification: aligned Android-selected category/detail item is a folder. No valid playable leaf was sampled; empty play URL is observed, but source playback failure is not established. Mark playback not-tested/no-valid-playable-sample. Peer refetched source203-site snapshots have10changed ext envelopes, including candidate wrappers differing in generated identity, reinforcing conditional rather than strict installed same-ext attribution. User active effective T4 config/prefs stayed equal in peer checks.
