# Episode Preload Compatibility Plan

**Goal:** Extend opt-in next-episode preloading to the JVM + HLS master + ad-cleanup combination seen in the field, while preserving foreground playback and authorization.

**Architecture:** Keep the current scoped cache and player handoff. Resolve JVM candidates in a separate playback worker because a JVM host owns only one media/asset proxy lease. Follow an unambiguous HLS master to one media playlist and apply the same cleanup as foreground playback before deriving duration and landing fragments.

## Constraints

- Defaults unchanged. One prospective JVM worker; cancellation never closes the current worker. Promote the media token and any scoped subtitles/danmaku owner together. Cold playback is always the fallback.
- Only one normal master variant with no alternate renditions; reject ambiguous masters, live, unsupported ranges, external/local-proxy media needing special transport, and unsupported parser or bridge paths. Preserve existing freshness, byte cap, foreground preemption and credential-origin behavior.
- Cleanup in speculation has no stats/toast side effects. Verify that the foreground serves the same cleaned timeline and reuses the targeted fragment.

## Tasks

- [ ] HLS: RED fixtures for a one-variant master and an actually edited VOD playlist in `test/episode_proxy_preload_test.dart`. Implement in `lib/services/proxy_server.dart` without changing the caller-visible inspect/prime/ready/finish contract. Test rejected master and existing cache/security cases.
- [ ] JVM: RED fixture for independent host and scoped assets. Implement the worker lifecycle in `lib/services/sidecar_runtime.dart`, the isolated direct resolver in `lib/services/site_service.dart`, and ownership promotion/disposal in `lib/state/app_state.dart`; verify discard, stale callbacks and old release cannot revoke successor.
- [ ] Lead acceptance: independently inspect both changes, run focused proxy/JVM/native playback and analyzer checks; document what remains unsupported and whether exercised against the real source.
