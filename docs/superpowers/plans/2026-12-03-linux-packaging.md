# Linux x86_64 Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Complete Linux native compilation, AppImage/deb packaging, CI and manual release without changing application UI or Windows behavior.

**Architecture:** Fan-out across three disjoint boundaries with the CLI and artifact contract fixed here. Flutter produces a Linux bundle; one Python packager stages the same runtime layout into AppImage and deb; workflows call that interface. Dispatcher reviews and verifies each deliverable independently.

**Tech Stack:** Flutter/Dart, GTK/CMake, Python 3 standard library, dpkg-deb, appimagetool, GitHub Actions.

**Spec:** docs/webhtv-pc-design.md:1997-2058; user confirmed full scope.

## Decisions

- Settled: Linux x86_64, AppImage and deb, bundled Node and all three sidecar hosts, CI and manual release.
- Assumed: Ubuntu 22.04 build baseline; Python 3 and JDK 17+ remain system dependencies, matching Windows distribution strategy.
- Ruled out: ARM64/macOS expansion, visible UI changes, Windows refactors, automatic publishing from push/PR.
- Acceptance: native runner, Linux media library, reproducible artifact metadata/checksums, exclusion of user/fixture data, package tests, workflows and documented local commands; real build where tools/network permit, otherwise explicit evidence of blocker.

## Global Constraints and Interface

- Existing Windows files are read-only except shared pubspec dependencies/lock; preserve Windows media support.
- Package staging has executable webhtv_pc beside lib/, data/, runtime/node/node, sidecars/. Keep Node executable permissions and relative symlinks.
- Sidecar allowlist follows scripts/package_windows.ps1:193-238. Include JVM manifest Class-Path jars and NOTICE; JS production node_modules plus package-lock.json. Never include fixtures, manifests/spiders, user data or credentials.
- Packager is Python stdlib scripts/package_linux.py and accepts --build-dir, --output-dir, --version (required), --build-number, --channel (stable|beta|dev), --commit, --short-commit, --built-at, --flutter-version, --tag, --notes-file, --node-version, --node-runtime-dir, --appimagetool. Defaults: bundle apps/desktop-flutter/build/linux/x64/release/bundle, output dist/linux, build-number 1, channel dev, Node v22.23.4 (verify official availability; notify dispatcher if unavailable), appimagetool on PATH. --node-runtime-dir points to a directory containing bin/node or node and its upstream license.
- Default output builds BOTH AppImage and deb. --formats accepts comma-separated appimage,deb (single format allowed for tests). Existing output files must not be silently destroyed on input errors; no recursive clearing of caller-supplied directories.
- Artifact stem webhtv-pc-<version><channelSuffix>-linux-x64; suffix is empty for stable, -beta for beta, -dev for dev. Outputs <stem>.AppImage, <stem>.deb, SHA256SUMS.txt, release-info.json.
- Metadata follows scripts/package_windows.ps1:497-540 with platform linux, arch x64, unsigned signature and assets for both formats. Include build/channel/tag/commit/builtAt/flutter and runtime requirements. Asset upload must avoid clobbering Windows shared-named metadata: upload Linux metadata as linux-SHA256SUMS.txt and linux-release-info.json on GitHub Release while artifact/local names stay unchanged.
- deb installs payload /opt/webhtv-pc and /usr/bin/webhtv-pc launcher with desktop integration; executable must find sidecars using its own directory, not caller cwd. deb dependency set derived from GTK, notification, mpv and bundle shared libraries.
- AppImage bundles required non-base native player dependencies, uses AppRun to set necessary library paths, supports APPIMAGE_EXTRACT_AND_RUN=1 in CI. No unsupported claim of zero system dependencies or all glibc versions.
- No commits, pushes or live releases requested. Commands/read/test runs unlimited inside boundary; at most 3 implementation runs per brief, cumulative.

## Task 1: Linux platform and native dependencies

**Boundary:** apps/desktop-flutter/linux/**, apps/desktop-flutter/pubspec.yaml, apps/desktop-flutter/pubspec.lock, apps/desktop-flutter/.metadata if required. Scope extension after verified CI hand_back: apps/desktop-flutter/lib/state/app_state.dart and one startup-architecture test. At most 15 edited files cumulative. Do not edit other application lib/ files, Windows runner, packager or workflows.

**Scope-routing record:** Existing app_state.dart:1932 used Dart version as Linux CPU architecture; the Linux x64 startup contract requires actual runtime ABI. Fix only Linux metadata, retain Windows behavior and actual player label media-kit (libmpv). This changes no API signature or visible UI. CI continues its same run after clean hand_back; no product decision reopened.
**Pointers:** apps/desktop-flutter/pubspec.yaml:14-18; apps/desktop-flutter/windows/CMakeLists.txt:1; lib/services/node_runtime.dart:55-92 (read-only).
**Consumes:** existing Flutter app and plugins. **Produces:** flutter build linux --release yielding bundle/webhtv_pc, lib/ and data/ with media-kit Linux support.
- [ ] Verify official Flutter SDK/version, Linux plugin requirements, and runner template before choosing dependencies. No lockfile guessing; use pub get or official package metadata with evidence.
- [ ] Add standard minimal Linux runner/CMake and Linux media library without UI redesign.
- [ ] Verify dependency resolution and native compile if obtainable; report environment/network blockers honestly. Inspect Linux-dependent runtime/test failures within boundary; hand back out-of-boundary defects.
- [ ] Report changed files, exact checks/results and SDK path reusable by dispatcher.

## Task 2: Packaging and package tests

**Boundary:** scripts/package_linux.py, scripts/linux/** (only necessary desktop/icon assets), tests/test_package_linux.py, .gitignore. At most 7 edited files cumulative.
**Pointers:** scripts/package_windows.ps1:193-238,497-540; docs/webhtv-pc-design.md:2011-2058; JVM host.jar manifest and lib/ (read-only).
**Consumes/Produces:** CLI and artifacts specified above.
- [ ] Write failing unittest cases using fake bundle and controlled tools/runtime; verify failure before implementation. Cover missing inputs, dangerous output overlap, sidecar allowlist/dependencies, executable modes, symlinks, both formats and metadata/checksums. Fake AppImage tests are not real AppImage validation.
- [ ] Implement staging, verified official Node download with license, deb and AppImage generation, notices/build inventory and metadata. Verify archive traversal/symlink safety and do not package external symlink targets or user fixtures.
- [ ] Run unittest, python compile checks and a real dpkg-deb roundtrip. Real AppImage where tool/network permit. Report package contents and separate real tools from mocked tests.

## Task 3: CI, release and usage

**Boundary:** .github/workflows/linux-ci.yml, .github/workflows/linux-release.yml, apps/desktop-flutter/README.md, docs/linux-packaging.md, tests/test_linux_workflows.py (optional). At most 5 edited files cumulative.
**Pointers:** .github/workflows/windows-ci.yml:17-72,115-184; windows-release.yml:17-66,116-192,315-345; docs/webhtv-pc-design.md:2011-2058.
**Consumes:** fixed packager CLI and existing JVM jars tracked in git. **Produces:** Ubuntu 22.04 build/test/package CI and workflow_dispatch manual stable/beta release with artifact retention and publish_release control.
- [ ] Install clang/cmake/ninja/GTK/mpv/notify/Xvfb prerequisites, Flutter compatible with pubspec/sdk and existing baseline, Node/npm ci, Python and JDK. Use tracked JVM host.jar/lib (no required PowerShell build).
- [ ] Resolve metadata safely; do not interpolate untrusted workflow inputs directly into shell code. Tags follow existing Windows scheme, and existing mismatched tag commit fails.
- [ ] Run analyze/tests, native build, packager and meaningful Xvfb smoke test; install/use a pinned and integrity-verified appimagetool. No unchecked continuous binary.
- [ ] Publish assets only after smoke succeeds and manual publish flag is true. Reusing a release uploads Linux assets without changing Windows assets, notes or prerelease state unexpectedly.
- [ ] Document local build dependencies, packager command, native package installation, glibc baseline, X11/Wayland manual checks, runtime requirements, known limits and manual dispatch workflow behavior.
- [ ] Validate YAML, embedded shell syntax and interface consistency. Report concrete commands/results.

## Review and acceptance

- [ ] Dispatcher reads each key diff and checks scope/acceptance against this plan. Runs 1 initially for each brief; specific rework uses same warm child, maximum total 3 runs.
- [ ] Run combined Python tests, workflow checks, Flutter pub get/analyze/build when available, deb/AppImage inspection and runtime smoke where available.
- [ ] Route every discovered defect for correction before delivery. Record environmental limits distinctly from defects.

## Initial acceptance record (before local build and beta merge)

- Delivery stays in wt/dev3; no commits, pushes, merges or live releases requested/performed. Preserve host-owned worktree.
- Task1 accepted after scope extension (run2/3): official Flutter3.47.5/Dart3.13.4 resolution, Linux runner/plugin/RPATH/native-assets review, actual ABI startup metadata, unchanged Windows branch. Dispatcher verified200 application/dependency/test inputs identical to validation copy, flutter analyze --no-pub exit0, focused startup-architecture+Node tests6 passed with1 Windows-host conditional skip.
- Task2 accepted (run3/3): dispatcher fresh26 package tests without skips using real appimagetool1.9.1 and dpkg-deb. Independent scoped review closed external Node/Python/JVM ancestor-link leakage and confirmed safe relative links. Script hash a48c515cba8909225f322014c57809e79ab1f8c213ae3c24e3ee4788bb50ddaa.
- Task3 accepted (run3/3 with clean scope hand_back): exact multiline ready protocol accepted, runtime architecture/player fields match actual app, process-tree-owned mapped X11 window required, post-ready exit checked. Both workflow smoke bodies match; independent20-scenario matrix9 tests passed, with real X11/deb and controlled GUI/AppImage wrapper.
- Dispatcher final combined Python tests:56 passed, no skips,79.517s. actionlint1.7.10, Python syntax checks and git diff --check pass. Windows workflow/runner/packager diff against cdf81d8 empty.
- Routed/closed defects: impossible Jammy libmpv2 dependency replaced by actual inventory; external ancestor-symlink payload escape rejected; real multiline startup protocol parsed; ready-then-crash/no-window false positives rejected; Linux startup CPU architecture resolved via actual Abi rather than Dart version. Independent re-reviews found no remaining load-bearing defect.
- Validation limitation: native Flutter build attempted but CMake failed because clang++ unavailable; host also lacks pkg-config and usable GTK/mpv/notify dev prerequisites, sudo-n requires interactive authentication. Real Flutter bundle, its deb installation/AppImage execution, playback, Wayland and older-glibc integration are NOT claimed verified. Actual package tools were exercised with controlled payloads; X11 window fixtures were real but not Flutter clients. Ubuntu22.04 workflows provision prerequisites for those pending integration checks.
- Session orchestration note: no Session child-route allowlist recorded; explicit deepseek-official/deepseek-v4.1-flash used consistently.

## 后续实际验证与提交范围

- 已在 Ubuntu 25.10 使用用户目录原生工具链成功构建真实 Linux x64 Release，并独立确认客户端就绪、X11 映射窗口、libmpv/Flutter 引擎加载和启动后存活；该本地构建不代表 Ubuntu 22.04、Wayland 或真实视频播放验证。
- 已快进合并最新 beta 提交 60ceb76，保留 Linux 支持改动；只修复三个新增设置测试的临时目录隔离，原业务断言和页面代码不变。
- 实际启动揭示构建标签含嵌套括号，已修复双工作流解析并通过真实启动信息回归及独立重审。
- 提交前新一轮验证：57 项 Python 测试通过；相关 Dart 回归 67 项通过、1 项原有 Windows 专项跳过；静态分析、工作流语法和差异检查通过；合并后最新源码的 Linux Release 构建成功。
- 本地 SDK、sysroot、node_modules、构建产物与执行台账均为忽略文件，不进入提交。完整 AppImage/deb 发布打包仍需发行版原生库安装与 dpkg 归属信息，本地免 root sysroot 不作为发行包环境。
- 按用户要求使用中文提交说明并推送当前 wt/dev3 分支；不直接改写 beta，不执行正式 Release 发布。
