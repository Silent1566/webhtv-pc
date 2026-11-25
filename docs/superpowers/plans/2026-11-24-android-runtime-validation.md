# Android Runtime Real-source Validation Plan

> For agentic workers: execute only this validation milestone, under the dispatch brief boundaries. No runtime/MVP implementation is authorized by this plan.

**Goal:** Measure whether the user-supplied Android emulator expands actual JAR-source coverage beyond the current desktop JVM path.
**Architecture:** Hybrid. Lead owns the ADB/HTTP seam and final acceptance; one worker owns Android business probes, a second owns desktop comparison. Shared Android business calls are not parallelized across workers.
**Tech Stack:** Existing ADB 37.0.1, Python read-only HTTP probes, existing Dart/JVM intake/host tooling.
**Spec:** [Feasibility report](../../reference/apkstart-android-runtime.md), its minimum validation section, and the user's emulator endpoint 192.168.50.3:5555.

## Global Constraints

- Preserve emulator data, active configuration, installed APK, accounts, and shared local ADB server 5037.
- No APK install/update/uninstall, force-stop, data clearing, root switching, settings writes, source/config mutation, or account actions.
- User-source binaries, ext/cookies/tokens, full signed URLs, and raw logs remain only in the plan's ignored scratch directories; tracked evidence is sanitized.
- ADB is the control channel; source business runs through the already-installed Android APK/T4 gateway.
- Successful HTTP response alone is not a successful source or successful playback. Mark not-tested, unsupported, empty, dependency-blocked, and failed separately.
- Desktop comparison is strict same-input only if JAR hashes and site configuration provenance can be matched. Same site name/key alone is insufficient.
- Task 2 MVP and subsequent installation/UI work require the validation gate first; they are outside this milestone.

## Task 1: Connection preflight — completed by Lead

- ADB executable: /home/maple/android-sdk/platform-tools/adb.
- Dedicated server: 127.0.0.1:5038; selected device: 192.168.50.3:5555.
- Android 9, API28; advertised ABI list x86_64,x86,arm64-v8a,armeabi-v7a,armeabi; native bridge libnb.so. Advertisement does not prove any native JAR works.
- APK: com.silent.android.webhtv, 5.6.0/code560, already running (PID5008 at preflight).
- Direct LAN port9978 timed out; owned ADB forward maps 127.0.0.1:35829 to guest9978.
- /device and /vod/api?ac=config return200 via the forward; gateway exports204 type4 sites.

## Task 2: Android real-source probe

**Write boundary:** docs/reference/evidence/android-runtime-2026-11-24/android-probe.{md,json}; own ignored scratch android/.
**Inputs:** frozen seam above; source definitions discovered read-only from installed app/current source configuration.
**Steps:**
- Snapshot config identity/site-key digest without exporting secrets.
- Select real cases covering ordinary dex, native/guarded source, Android/UI dependency and media proxy where the current configuration provides them. Do not assert a category from names alone.
- Call T4 home/category/detail/search/play sequentially per case with finite deadlines and supported operation awareness.
- Probe returned media with request headers preserved: bounded playlist/range/segment requests, including guest-local proxy when returned. No bulk downloading and no account interaction.
- Capture latency, payload counts, byte bounds, request/response fingerprints, failures and relevant sanitized app diagnostics. Capture current RSS; cold start is not tested because force-stop is disallowed.
- Confirm active config identity remains unchanged; produce JSON and a concise Markdown matrix, with runtime success separated from media reachability/decoding.

## Task 3: Desktop same-source comparison

**Write boundary:** docs/reference/evidence/android-runtime-2026-11-24/desktop-probe.{md,json}; own ignored scratch desktop/.
**Inputs:** current PC SQLite/registry/cache, read-only Android binary/config provenance if accessible, current intake/JVM code.
**Steps:**
- Inventory cached JARs/site bindings and identify intersection with current Android site keys.
- Match source hash/config provenance; copy source material to private scratch before any translator/JVM call. Never modify live PC configuration, manifests, or source cache.
- Run existing intake/translation/host diagnostics in scratch for eligible matched samples. Keep current native refusal and existing limits; do not hack production code or classifier to force execution.
- Record actual desktop failures/successes and whether each result is a strict same-input comparison or only a baseline support-boundary observation.
- Report when exact Android configuration/JAR provenance is unavailable; do not turn unmatched samples into compatibility uplift claims.

## Task 4: Lead acceptance and hand-off

- Read both final artifacts and check every input/claim/provenance boundary.
- Re-run at least one positive source business path, inspect any claimed native/UI uplift, and verify the media reachability evidence. Decode/render playback remains untested unless separately demonstrated.
- Check source configuration was not changed; distinguish warm-call timings/RSS from cold-start measurements.
- Save accepted findings to evidence README, including blockers and exactly what Task2 can safely assume.
- Restore only our own forwarding/ADB resources when no longer needed; do not stop the emulator or shared ADB5037.

## Gate

Pass requires attributable successful Android source business that meaningfully exceeds current desktop coverage, plus explicit media evidence and acceptable measured costs for the tested samples. If source/config equality or media/ABI is not proven, report a conditional or blocked gate, not universal compatibility.
