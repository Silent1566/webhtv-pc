# Cross-platform test directory isolation repair

Goal: Stop Flutter tests writing real Linux/macOS user directories while retaining Windows isolation.

Approved scope: User selected all same-kind test defects. Only tests, regression checks, and this plan change. Production AppPaths, UI, user data, and release artifacts stay untouched.

## Design and decisions

Use existing explicit AppPaths.resolve overrides config, data, cache, state. Preserve the Windows fixture layout: config=<roaming>/webhtv-pc; data=<local>/webhtv-pc; cache=<local>/webhtv-pc/cache; state=<local>/webhtv-pc/logs. Production semantics stay unchanged. Replace unsupported log keys with state, keeping their original value. Ruling: preserve all bytes outside override map bodies; SDK full-file formatting failure is accepted only when its exact files/count match pre-change baseline. This avoids unrelated formatting churn while analyzer and functional checks remain mandatory.

Execution topology: Fan-out after regression guard RED. Three disjoint manifests in .local/test-isolation-repair/group-{1,2,3}.json partition 96 Dart test files. Separate guard owner edits tests/test_linux_path_isolation.py only. No shared Flutter build/test processes during parallel migration; dispatcher performs runtime acceptance afterward.

## Task book

1. Regression guard (run 1/3): create tests/test_linux_path_isolation.py; scan Flutter unit and integration AppPaths literal override maps. Reject unsafe Windows-only and log keys. Test detector with positive/negative fixtures; show expected RED on current repository. Sources: app_paths.dart:39-84, phase9_following_unread_test.dart:233-242, nav_source_detail_ui_test.dart:332-372.
2. Migration group 1 (run 0/3): edit only group-1 manifest. Convert unsafe overrides to explicit four-directory keys. Validate containment and syntax. Adjust only dependent fixture path assertions, not production behavior.
3. Migration group 2 (run 0/3): same contract on disjoint group-2 manifest.
4. Migration group 3 (run 0/3): same contract on disjoint group-3 manifest, including unsupported log-key replacements where present.
5. Independent acceptance: guard GREEN; default/persistence and two leak repros in fresh HOME/XDG; affected Flutter unit suites and static checks on integration files; check default-profile app settings, database and logs remain absent; read diffs and containment. Compare real user config baseline without modifying it. Rework goes to boundary owner, at most three runs per brief.

## Acceptance

- No Windows-only roaming/local or unsupported log isolation remains in scanned test trees.
- Config/data/cache/state stay inside fixture-owned directories through existing explicit overrides on every platform.
- Regression guard catches old forms (RED) and accepts complete repair (GREEN).
- Following and episode defaults remain unchanged; leak repro tests no longer create app files in isolated default profile.
- Relevant tests and analysis pass; no production edits or user data mutations.
- Existing user-visible icon semantics are outside scope and unchanged.

## Preflight review

Guard and migration boundaries are disjoint. All migration tasks consume existing AppPaths keys and create no API. Whole-tree guard stays RED until all migrations land. Runtime builds and tests serialize after migration to avoid cache races. The approved conversation is the specification; no separate architectural spec is needed for this mechanical repair.

## Verification ledger

- Guard run 2/3: detector and repository check independently passed 9/9. Original 125 unsafe calls produced RED; XDG-only safety loophole was corrected through RED/GREEN.
- Group 1 run 2/3: 32 files, 40 conversions; unrelated formatter churn removed.
- Group 2 run 1/3: 32 files, 36 conversions; clean hand-back resumed without charging a run.
- Group 3 run 1/3: 32 files, 49 conversions; same clean hand-back policy.
- Independent audit: all 96 files, 123 root-preserving expansions, 2 log-to-state renames, zero changes outside map bodies, zero production diff.
- Corrected Flutter acceptance: 883 tests passed across 75 executable test files; isolated XDG config/data/cache/state remained free of application directories.
- Python repository suite: 66 tests passed. User settings SHA256 and target fields match captured baseline.
- Combined independent Dart analysis: all 96 files, exit 0, No issues found.
- Initial verification-command failures were corrected by restoring existing libmpv sysroot path and excluding the helper without main. No source workaround was added.
- Independent Standards/Spec review accepted the 96-file migration and found two guard durability gaps. Both are routed to guard run 3/3: use test_linux_path_isolation.py to match existing CI test_*linux*.py discovery; reject obsolete roaming/local keys even alongside all direct keys. Production/workflow files remain untouched.
- Guard run 3/3 independently verified: 11/11 focused tests pass; the exact CI discovery pattern test_*linux*.py runs 47 tests (OK, 1 optional AppImage skip) and includes the guard. Old guard filename is absent.
- Final boundary checks: accepted Dart diff byte-identical, no production/workflow diff, user settings SHA256 unchanged.
- Scoped re-review completed: F1 and F2 ADDRESSED; Standards PASS; Spec PASS; no new regression defects. Repair accepted. User subsequently requested a commit and push with a Chinese description.
