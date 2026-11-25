# Existing Android Environment MVP Implementation Plan

> For agentic workers: use the dispatch briefs for assigned modules; at most3runs per brief, no editing an active peer's write scope.

**Goal:** User-selected existing ADB/AVD environments can supply installed WebHTV/T4 sources without manually maintaining temporary port mappings.
**Architecture:** Hybrid. Lead owns and freezes the descriptor/runtime interface with tests; downstream state/UI adapters and scoped proxy work are delegated only after their consumed interfaces are settled. Lead owns final acceptance.
**Tech Stack:** Dart/Flutter, installed Android platform-tools/emulator CLI, current HTTP/streaming proxy, existing SQLite/settings persistence.
**Spec:** [MVP design](../specs/2026-11-24-android-adb-mvp.md); [real validation](../../reference/evidence/android-runtime-2026-11-24/README.md).

## Global Constraints

- Use existing installed environments; no APK/image install, wipe, account actions or silent VM launch.
- No shared ADB shutdown; own only newly created forwards/processes, keep borrowed mappings/server intact.
- Persist stable profile/device/source identity, not a forwarding port alone; guard stale-loopback config activation.
- HTTP/T4/sourceKey/auth semantics remain backward compatible; only internal optional transport metadata is added.
- Logs/evidence have no raw ext/credential/full signed media URL. Explicit sources can fail403; never turn failures into fake success/empty lists.

## Task1: Lead descriptor core (run1)

Files: create lib/core/android_adb_profile.dart and test/android_adb_profile_test.dart under apps/desktop-flutter.
Interface: AndroidAdbMode(network,device,avd); AndroidAdbProfile(mode,target,adbPath,emulatorPath,avdHome,serverPort,gatewayPort), toJson(), static fromJson(Object?), connectionKey.
- [ ] Write literal-fixture tests for normalizedTCP/default5555, explicit borrowed serial/server, AVD paths, malformed/future metadata, invalid credentials/control/ports, stable identity.
- [ ] Run flutter test test/android_adb_profile_test.dart; confirm RED due missing descriptor behavior.
- [ ] Implement smallest validated version1 model; rerun GREEN; format/analyze changed files.

## Task2: SDK runtime adapter (delegated run1/3 after descriptor freeze)

Files: create lib/services/android_adb_runtime.dart and dedicated test/android_adb_runtime_test.dart; reuse AndroidBridgeService and device model.
Interface consumed by adapters: connect(profile,{expectedUuid,launchAvd=false}) -> Future<AndroidDevice>; enumerate device serials/AVD names; profileForUuid/deviceForUuid; managed gateway/media address resolver; disconnect(uuid); close(). Precise callable interface freezes after core tests and is published in adapter briefs.
- [ ] Write failing ownership/selection/timeout/rollback/UUID tests using controlled SDK/HTTP fixtures.
- [ ] Implement bounded SDK commands and loopback-only owned server. Verified SDK37syntax is -L tcp:<port> server nodaemon (hostname form fails); --one-device filters unrelatedUSB.
- [ ] Borrowed-device mode checks existing server/protocol before commands and never starts/kills it. AVD launch must be explicit and match actual selected AVD, not firstdevice.
- [ ] Test gateway probing and forward cleanup/reuse; no port/control action leaks after close.
- [ ] Freeze core external interface; run existing36baseline tests plus new runtime tests.

## Task3: Scoped media proxy adapter (brief after read-only seam finding)

Source: services/proxy_server.dart and core/proxy_policy.dart. Verified optional immutable ProxySession.targetResolver / ProxySessionManager.create targetResolver: Future<int?> Function(Uri logicalTarget). Resolve top/children/redirects in logical namespace; construct and validate only literal127.0.0.1:verifiedPort physically. Reuse token/header/Range/HLS; add bounded XML DASH rewrite (xml already direct dependency), preserve template/directory semantics and ordinary policy. No alternate generic proxy.
- [ ] Write RED tests for managed guest childURI mapping, wrong-device refusal, preserved headers/range, token invalidation and normal HTTP/HLS.
- [ ] Implement the verified optional seam; exact signatures/files are the task brief contract, not guessed by workers.
- [ ] Test complete HLS/DASH graph URI mapping with controlled fixtures; 403 remains an error.

## Task4: State/persistence/UI adapter (brief after core freeze)

Expected modules: state/sync_state.dart device history and connection flow; state/app_state.dart activation/restore/playback wiring; services/storage.dart optional internal transport marker; services/android_playback_bridge.dart managed resolver hook; ui/config_pages.dart existing AndroidSettingsPage or focused extracted form; matching focused tests.
- [ ] RED tests for history roundtrip/reconnect,newport on restart, wrongUUID, no active-config switch on failedconnect, stable bridge sourceKey, old HTTP unchanged.
- [ ] Persist description/marker, use fresh endpoints before cached config APIs, handle missing/corrupt metadata explicitly and never hit a stale managed port.
- [ ] UI supports explicit SDK/target/AVD choices, saved-profile reconnect and actionable errors using existing DESIGN.md patterns.
- [ ] Capture before/after existing page and after new form at same viewport/theme; no user data needed.

## Task5: Lead R6 and hand-off

- [ ] Read final diffs and criteria, run focused regression/analyze and risk-relevant realSDK/204-site/Media-range test using temporary PC state.
- [ ] Check unchanged user config/APK/old HTTP behavior and cleanup only owned forwards/processes.
- [ ] Record honest limits (native/originalJAR/decode/fullplayback, realAVD/otherOS when not run); route review defects before delivery.
