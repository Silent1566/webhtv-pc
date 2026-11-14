# Linux x86_64 build, packaging and release

Linux produces **both AppImage and deb**. Windows workflows and release assets are independent and unchanged. ARM64 and macOS are outside this build target.

## Build host

Use Ubuntu 22.04 x86_64 (glibc 2.35) or a compatible build container with a display available for tests. Building on a newer distribution can raise the minimum glibc/library requirements: it is not a compatibility test for older systems. Packages are not signed, and there is no automatic update channel.

Flutter **3.47.5 / Dart 3.13.4** matches the existing Windows baseline and pubspec SDK constraint. Verify the SDK with `flutter --version`; do not substitute an arbitrary SDK or edit the lockfile by hand. The official SDK archive is at <https://docs.flutter.dev/install/archive>. CI's pinned Flutter setup must fail rather than silently use another version if upstream acquisition fails.

Install the native prerequisites:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends -y clang cmake ninja-build pkg-config \
  libgtk-3-dev libmpv-dev libnotify-dev liblzma-dev libstdc++-12-dev \
  xvfb xauth x11-utils dpkg-dev
```

Also install Python 3 (CI uses 3.12), JDK 17+ (CI uses Temurin 21), and Node.js 22 with npm. Node on the build host is used for npm/JS tests; the packager bundles the official Node **v22.23.4** runtime with its upstream license and verifies the downloaded archive against official SHA256 checksums. A local Node runtime can instead be provided with `--node-runtime-dir`, pointing to a directory containing `bin/node` or `node` and its upstream license.

Ubuntu 22.04 ships mpv 0.34.1, so `libmpv1`/`libmpv-dev` provide **libmpv.so.1**, not a `libmpv2` soname. Do not hardcode a soname: the packager resolves the real player library from the build host's `ldconfig`/`ldd` inventory and fails with an actionable error when no `libmpv.so.*` is found.

The JVM host and its manifest Class-Path dependency jars are **tracked** under `sidecars/spider-host-jvm/host.jar` and `lib/`. Neither the Linux workflows nor local packaging require a new JVM build script or PowerShell build. Keep their NOTICE files intact.

## Local build and packaging

Run from the repository root, with the pinned Flutter SDK on PATH:

```bash
(cd sidecars/spider-host-js && npm ci --omit=dev)
(cd apps/desktop-flutter && flutter pub get && dart analyze)
(cd apps/desktop-flutter && flutter build linux --release --dart-define=APP_VERSION=0.1.0)
(cd apps/desktop-flutter && xvfb-run -a flutter test)
python3 -m pip install PyYAML==6.0.2
python3 -m unittest discover -s tests -p 'test_*linux*.py'
```

Use the app's pubspec version (currently `0.1.0+1`) rather than the example version after it changes. Build before running player tests; do not skip native-player tests to conceal missing libraries.

### Building without root (user-local toolchain)

A user-local toolchain can compile and run the client without installing system
packages. The local verification used Ubuntu 25.10 and unpacked 187 native
packages into an ignored sysroot, then prepared compiler wrappers and an overlay
for already-installed host headers/libraries. APT's simulated install lists only
missing packages: unpacking that list alone is **not** a complete generic setup.
A fresh checkout does not contain the ignored SDK, sysroot or environment wrapper.
Use the Ubuntu 22.04 prerequisites above or the CI build for a reproducible
standard environment.

Once a user-local toolchain and its environment wrapper have been prepared, run
from the repository root:

```bash
test -f .local/linux-build/environment.sh
source .local/linux-build/environment.sh
flutter --version
(cd apps/desktop-flutter && flutter build linux --release --no-pub \
  --dart-define=APP_VERSION=0.1.0)
GDK_BACKEND=x11 \
  ./apps/desktop-flutter/build/linux/x64/release/bundle/webhtv_pc
```

The wrapper must configure the Flutter SDK/compiler PATH, workspace TMPDIR,
pkg-config sysroot and library/include search paths. Source it in each new shell.
The executable needs the accompanying lib/ and data/ directories; this local
bundle is not a standalone distribution package or an older-glibc compatibility
claim. Use --no-pub only after dependency resolution has already succeeded.

User-local unpacked libraries are not registered with dpkg. The current packager
uses system library discovery and dpkg ownership to derive Debian Depends, so
this local sysroot is suitable for compilation/testing, not AppImage/deb release
packaging. Build those artifacts on the documented host or in CI.

Download and verify the **pinned official appimagetool 1.9.1** before executing it. A changed upstream binary must fail verification until explicitly reviewed.

```bash
mkdir -p .local/linux-tools
curl --fail --location --retry 3 \
  https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  --output .local/linux-tools/appimagetool-1.9.1.AppImage
printf '%s  %s\n' \
  ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 \
  .local/linux-tools/appimagetool-1.9.1.AppImage | sha256sum --check
chmod +x .local/linux-tools/appimagetool-1.9.1.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 .local/linux-tools/appimagetool-1.9.1.AppImage --version

APPIMAGE_EXTRACT_AND_RUN=1 python3 scripts/package_linux.py \
  --build-dir apps/desktop-flutter/build/linux/x64/release/bundle \
  --output-dir dist/linux --version 0.1.0 --build-number 1 --channel dev \
  --commit "$(git rev-parse HEAD)" --short-commit "$(git rev-parse --short=7 HEAD)" \
  --built-at "$(git show -s --format=%cI HEAD)" --flutter-version 3.47.5 \
  --node-version v22.23.4 \
  --appimagetool "$PWD/.local/linux-tools/appimagetool-1.9.1.AppImage"
(cd dist/linux && sha256sum --check SHA256SUMS.txt)
```

The default command builds **both formats**. `--formats appimage` or `--formats deb` is for deliberate single-format checks, not the full CI/release build. Optional metadata inputs are `--tag` and `--notes-file`. No workflow input is interpolated into shell source; workflow metadata is passed through environment variables and validated.

Output contract:

| Channel | Asset stem |
| --- | --- |
| stable | `webhtv-pc-<version>-linux-x64` |
| beta | `webhtv-pc-<version>-beta-linux-x64` |
| dev | `webhtv-pc-<version>-dev-linux-x64` |

Each full build writes `<stem>.AppImage`, `<stem>.deb`, `SHA256SUMS.txt` and `release-info.json` into `dist/linux`. Metadata includes platform/architecture, unsigned status, build/channel/tag/commit/time/Flutter information and runtime requirements. Existing unrelated files in an output directory are not disposable; use a dedicated output directory, never your bundle or source directory.

Both payloads keep `webhtv_pc` beside `lib/`, `data/`, `runtime/node/node` and `sidecars/`. Packages include the allowed host scripts/jars, JS production dependencies, lockfile, licenses and notices—not site sources, fixtures, user configuration, credentials, cookies or logs.

## Install and run

```bash
# Native Debian/Ubuntu installation; apt resolves declared native dependencies.
sudo apt install ./dist/linux/webhtv-pc-0.1.0-dev-linux-x64.deb
webhtv-pc

# AppImage: normal runtime may require FUSE support on the target distribution.
chmod +x dist/linux/webhtv-pc-0.1.0-dev-linux-x64.AppImage
./dist/linux/webhtv-pc-0.1.0-dev-linux-x64.AppImage
# Without FUSE (as in CI), extract and run the same AppImage runtime:
APPIMAGE_EXTRACT_AND_RUN=1 ./dist/linux/webhtv-pc-0.1.0-dev-linux-x64.AppImage
```

The deb installs into `/opt/webhtv-pc` with the launcher `/usr/bin/webhtv-pc` and desktop integration. Sidecars are located relative to the executable, not the caller's current working directory. Removing the package (`sudo apt remove webhtv-pc`) does not require deleting user data.

AppImage bundles required non-base player libraries, but **does not eliminate system dependencies**: the host still supplies compatible glibc, GTK/display services and graphics drivers. Python/JVM sources need local Python 3 / JDK 17+; Node is bundled. There is no guarantee for older glibc versions or every distribution. Refer to the generated deb dependency metadata (`dpkg-deb --field <package>.deb Depends`) and package inventory rather than assuming identical requirements on all machines.

## CI and manual publishing

- `.github/workflows/linux-ci.yml` runs on pushes to `main`/`dev*`, PRs to `main`, and manual dispatch. It has read-only repository permissions, never publishes a release, and retains workflow artifacts for **7 days**.
- `.github/workflows/linux-release.yml` is **workflow_dispatch only**, with `release_tag`, `release_channel`, `release_notes`, `prerelease` and `publish_release` inputs. It retains workflow artifacts for **30 days**, including when `publish_release=false`. The workflow must be on the default branch for GitHub's manual Actions UI to register it.
- Channel `auto` means stable on `main` and beta elsewhere. Tags use the Windows scheme: `v<version>-yyyyMMddHHmm` or `v<version>-beta-yyyyMMddHHmm`, using the **commit's timestamp in Asia/Shanghai**, not rerun wall-clock time. Explicit tags must match the resolved version/channel. Existing tags (including annotated tags) must point to the same commit; they are never moved.
- Analyze, all Flutter tests, native build, both packages, checksum validation and Xvfb smoke must succeed before any publishing. Smoke checks package layout and bundled Node execution, then launches the extracted deb payload (relocated to a space/non-ASCII path) and the actual AppImage with `APPIMAGE_EXTRACT_AND_RUN=1`, both from outside either payload. It parses the documented ready protocol line by line — `ready <timestamp>`, then the `startupInfo` line, then the trace summary — and rejects a bare `startup-info-unavailable` sentinel. The startupInfo line must report the exact version, `platform=linux`, `arch=x64` and a `media-kit` player (whose engine label carries the libmpv backend), so a mismatched build fails instead of passing on one substring. After readiness it requires an actually mapped X11 window whose `_NET_WM_PID` belongs to the launched process tree (`xwininfo`/`xprop`), then re-checks the process 3 seconds later so a crash or self-exit right after the marker still fails. Every wait is bounded. The marker plus window proves bootstrap and window mapping only: this is **not** a real apt-install test and not proof of Wayland behaviour, video decoding or audio output. CI installs `x11-utils` for that assertion, and the smoke client can be a controlled GUI fixture, so a green smoke is not by itself evidence of a real Flutter build.
- `publish_release=false` creates no tag/release and uploads no release assets. With true, only Linux assets are published. Release metadata files are copied/uploaded as **`linux-SHA256SUMS.txt`** and **`linux-release-info.json`** to avoid Windows name collisions; local/workflow artifact names remain unchanged.
- A new release uses the supplied/generated notes and prerelease input (beta always prerelease). Reusing an existing release uploads/replaces **only Linux assets**, without editing its title, notes or prerelease state. Existing Windows assets remain untouched. To share a Windows release, select its exact tag and commit. Any changes to existing release policy/notes require a separate deliberate publisher action.

Example artifact-only manual run (no live publishing):

```bash
gh workflow run linux-release.yml --ref main \
  -f release_channel=stable -f publish_release=false
```

## Manual acceptance checklist and known limits

Record distribution/glibc (`ldd --version`), GPU/driver, desktop session and package format for each check; report real native tests separately from fake packager fixtures.

1. On Ubuntu 22.04 and a newer supported distribution, verify checksums, AppImage execution, real deb installation/launcher, upgrade and removal without losing existing user data.
2. On **X11 and Wayland**, check startup, full screen, resizing, keyboard/mouse input, notifications and shutdown. Xvfb exercises X11 only; Wayland compatibility must be recorded manually.
3. Exercise media playback/full screen, audio and GPU/software decoding using an authorized local file or test source. A ready signal is not proof of decoding or audio output.
4. Test paths with spaces/non-ASCII and launching from another directory. Verify bundled JS plus system Python/JVM sources and dependency failures; never include real source credentials in artifacts.

CI is an Ubuntu 22.04 baseline, not evidence of support for all glibc versions. GPU behavior, FUSE restrictions and Wayland compositor differences remain target-environment checks. Mock AppImage tools or fake Flutter bundles in package tests validate packaging logic only; they do not establish a real native-client build or GUI smoke result.
