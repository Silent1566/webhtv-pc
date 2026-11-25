# Existing Android Environment MVP — Design

## Scope and decisions

- User selected existing-environment MVP on2026-11-24; use installed WebHTV/T4 through explicit existing device/AVD selection.
- Preserve existing HTTP/LAN entry and source identities. No JAR upload, APK/system-image installation, wipe-data, account/UI automation or global ADB shutdown.
- Public interface hides local forwarding ports. Persist a validated version1 connection description, never a temporary port alone.
- Existing-device or already-running AVD mode may borrow a configured localhost ADB server; never starts/kills it. Network/explicit AVD-launch mode owns a loopback-only ADB nodaemon process and filters unrelated USB discovery. Borrowed operations use direct host-protocol sockets, not CLI auto-start behavior.
- Only explicit AVD launch starts an existing AVD; reconnect/restore must not launch user VMs or stop them at application shutdown.
- HTTP/T4 and exact device UUID remain the identity/auth/source-key semantics. ADB is only a PC transport; no Android protocol/ABI changes.

## Core descriptor

Create lib/core/android_adb_profile.dart. AndroidAdbMode is network/device/avd. AndroidAdbProfile accepts mode,target,adbPath,emulatorPath,avdHome,serverPort(default5037 for borrowed-device mode),gatewayPort(default9978).

- Normalize network target host:port, default5555; bracketedIPv6 supported. Reject HTTP URLs,userinfo,path/query/fragment,invalid ports,empty/flag/control/whitespace inputs.
- Device target is an explicit ADB serial; AVD target is an exact SDK-listed name. Never choose first connected device or assume emulator5554.
- Paths are local executable/directory references; empty means discovery. Reject remote URLs/control characters. Validate file/tool/version at execution, not model construction.
- toJson/fromJson version1 roundtrip; malformed/future metadata returns null without an exception leaking to settings recovery.
- connectionKey is stable across serialization and default-port normalization; different target/tool/AVD root/ports do not alias. No ephemeral forward fields serialized.

## Runtime and adapters

Runtime hides command framing/timeouts, SDK discovery, isolated/borrowed server ownership, device/AVD enumeration, explicit AVD launch, gateway probe, UUID matching, forwarding leases and rollback.

The state adapter persists connection description by device UUID locally. ADB-origin configs carry an internal transport marker; startup/activation refreshes their endpoint through the description or fails explicitly before using a stale port. Keep bridge|uuid|interfaceKey stable and do not switch/delete a user's current config on import.

The playback adapter pins only the exact logical origin from the actual returned media URI (e.g. guest5000), using the originating site/service gateway. Never infer the media port from gatewayPort9978 and never lazily authorize the first token request. Preserve path/query/headers/format and coordinate media resource ownership. Existing global HTTP/LAN behavior stays unchanged. HLS/DASH child URI mapping belongs behind the current tokenized streaming proxy, not ad-hoc string replacements. Its exact existing seam is independently inspected before modifying that module.

UI stays in AndroidSettingsPage and existing settings visual system. Add an explicit existing-environment connection entry, modes/SDK path/target/AVD selection, recognizable diagnostics and saved-target reconnect. Do not add a runtime downloader or emulator-window embedder.

## Verification and guardrails

- Baseline: phase5_android_bridge_test.dart + phase5_android_playback_bridge_test.dart36passed before edits.
- TDD: descriptor validation/roundtrip/identity; process ownership/no wrong device/rollback/deadline; persisted reconnect with changed local ports; unchanged source key; token/header/range/HLS/DASH mapping; UI old HTTP/new entries and saved-target behavior.
- Inject only external SDK/process/HTTP dependencies in tests; assert actual model, state, resource and media outputs. No test-only production cleanup methods.
- Visual before/after same scenario/viewport/theme for existing settings page risk; additive new form capture plus note where no prior UI exists.
- R6 real validation on192.168.50.3:5555 uses isolated PC paths/DB/settings, finite media samples, no user APK/config/account mutations. AVD has no installed local emulator on this host; exercise its command/selection path with controlled SDK fixtures, report real-AVD/Windows validation limits honestly.

## Integration decisions (2026-11-24, Lead)

- **Connection record lives in its own file** (configDir/android_connections.json), not settings.json and not deviceHistory: a saved AVD/auto-connect target must be reconnectable before /device has ever answered, while deviceHistory only stores reachableBase.
- **Always connect() before use.** Restore/activation calls the runtime first, takes the fresh loopback base from AndroidDevice, then re-imports/refreshes. No gatewayForUuid API is added; no cached port is ever trusted.
- **Legacy records stay legacy.** Managed records carry an additive bridge_transport='adb' column (schema 12→13); sourceKey keeps bridge|uuid|interfaceKey because parseSourceKey folds later segments into interfaceKey.
- **One forward owner per session.** Managed records pass a null playbackBridge so the legacy AndroidPlaybackBridge cannot create a second forward or double-map the top URL; the session resolver owns top and child mapping.
- **Port rule:** the gateway local port is never assumed, and startProxy's 9978 preference carries no promise for managed sessions; guest 9978/5000 exist only as logical origins inside a resolver session.
