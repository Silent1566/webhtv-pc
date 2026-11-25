# Android real-source validation — 2026-11-24

**Status: ready (evidence complete); milestone gate: conditional, not an Android runtime implementation approval.**

Existing APK5.6.0 / Android9 API28 / PID5008 was probed without installation, UI/account actions or production edits. Business cases were sequential. HTTP200 is not source/media/decoded-playback success.

## Reproducible matrix

| Case / evidence category | Home classes/list | Category/detail/search lists | Play/media result | Warm home repeat |
|---|---:|---:|---|---:|
| AList — ordinary dex remote-forward adapter | 15/60 | 20/1/60 | Selected category/detail is vod_tag=folder. Detail supplied route-shaped pair; play empty. No valid leaf playback sample, **not tested**, not source-wide failure. | 259.3ms |
| Media — ordinary dex adapter, Android UI dependency baseline | 29/4 | 2/1/21 | Real episode -> guest5000 proxy; MP4/206,65536B twice, zero and nonzero ranges, ftyp. **Bounded reachability only**, no decode/render. | 71.3ms |
| BiliBili — ordinary dex adapter | 31/28 | 29/1/110 | DASH200/20724B/15reps(12video+3audio); returned video/audio BaseURLs403HTML/552B each,3range samples. **Manifest reachable, representations denied.** | 347.2ms |
| Native Danmaku — native-containing plugin jar | 1/0 | 12/1/0 | Settings menu, action fields never invoked; detail config marker/noepisodes. Search not applicable. Packaged ARM goproxy, **native execution not proven**. | 9.3ms |
| wv_yszb — custom registry WvSpider/native libjsc | not tested | not tested | Exact WvSpider DEX descriptor + archive WebView/WebViewClient refs. **Not testable under no-UI-interaction constraint**, not compatibility failure. | not tested |

## Attribution, unchanged state and limits

- Effective inventory204 T4 exports; subscription119 type3 +84 type4=203 plus custom injection. JSON contains204 key fingerprints, not raw user identifiers.
- Key digest matches preflight: aa4e383ae4ebf5055882ae83ff04eb2e7c5578537872e325dbacb3a1a8fe7a06. Effective canonical config SHA256 before/after: be516671b2a94450f2d18bfca9fa653007c663314f822d35657b7088d9bb11d0. **All persisted preference elements are identical**, including active selector and credential-bearing settings.
- Original HTTP refetch differs in10ext envelopes; tested wrapper differences decode only to generated uid. Gateway hides ext; Config DB json is null; Site DB has only key/searchable/changeable. **Strict installed ext equality is not proved.**
- Loader logs attribute AList/Media/Bili to fae799 dex SHA25613eb1b6ae4b9203f88564d4e98be830a73dc294a82588a2be537f79176160e67. Ext is a remote-forward envelope. Business success is not proof original upstream scraper/native business runs on Android.
- Native plugin maps83667/libgoproxy ARM32/64; Wv mapsde84/libjsc ARM32/64+x86/64. Maps before/after already contain libjsc/libnb, **no libgoproxy**; global maps/packaging/ABI do not prove case-specific native execution. No active guarded VOD case was attributed.
- Media/Bili returned http guestloopback5000 URLs and **empty header objects**. These were preserved; only Range was added. Hostloopback requests initially failed ConnectionRefusedError errno111; corrected only in test mapping of proven guest authority, retaining path/query/headers. Bili403 means access denied, exact credential/signature cause unknown.
- Worker-owned tcp:0->guest5000 forward removed. Lead35829->9978 and35413->5000 retained untouched; owned server5038 and user emulator/APK/accounts preserved; shared5037 unused.
- RSS374796->375136KiB (+340); HWM388332->393456KiB; threads96->100. Already-running warm snapshots, not cold-start or sustained performance measurements.
- All4 business cases remained within original180s budgets (JSON carries counts/deadlines/latencies/fingerprints);5selected including untestedWv, cap6. Actual media/error response bodies 153452B; conservative ledger 153796B includes failed guest-tool text. Default64KiB, no request above1MiB, media25s/business35s deadline, total8MiB ceiling.
- Media first64KiB3219.4ms, nonzero64KiB373.9ms; samples, not sustained proxy throughput or decoding benchmarks.

## Reproduction and unverified gates

GET /vod/api?key=<case> through existing35829: home ac=detail&f=1; category add t=<returned type_id>&pg=1&ext=e30=; detail ids=<returned vod_id>; relevant advertised search wd=<returned title>&quick=0&pg=1; play play=<returned episode ID>&flag=<matching line>. Split vod_play_from/url by $$$, episodes by #, first dollar separates title/ID. Folder/menu records are not valid playback samples. Never invoke menu action payloads.

Private request/body/config/JAR provenance and executable scripts remain in declared ignored android scratch. JSON records exact request/body SHA256 and safe parameter shapes; no raw URLs/query values/tokens/credential-header values/user identifiers are exported. Reproduction uses private real returned IDs, not invented fixtures.

Unverified: decoding/rendering and full playback; cold/recovery start; cancellation/reconnect/concurrency/config isolation; CPU/disk/sustained proxy cost; native/guard execution; installed ext equality; UI Wv business. Native settings search initially attempted under advertised flag, returned0, is explicitly not applicable. Guest scratch SyntaxError/quoting and evidence-builder parse failure occurred before HTTP/artifact mutation and are recorded as tooling failures, not media failures.

**Conclusion:** Media supplies attributable local dex-adapter business plus real bounded MP4 proxy reachability. Desktop comparison shows a Media LinearLayout host boundary, while AList/Bili already return business through the remote-forward adapter on desktop. This supports at most **conditional adapter/UI coverage**, not original scraper/native uplift, universal compatibility or decoded playback.
