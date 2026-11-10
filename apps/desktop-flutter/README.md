# WebHTV PC desktop client

Flutter desktop player with media-kit and bundled sidecar hosts. Windows remains supported; Linux x86_64 builds produce AppImage and deb packages.

## Development

Use Flutter **3.47.5** (Dart **3.13.4**) to match the SDK constraint and CI baseline:

```bash
flutter --version
flutter pub get
dart analyze
flutter test
```

Run those commands in this directory. Linux native-player tests need the native dependencies installed and should run after the release build, under Xvfb when no display is available.

## Linux build and packages

See [Linux packaging and release guide](../../docs/linux-packaging.md) for Ubuntu 22.04 prerequisites, pinned/integrity-checked appimagetool, local build/packager commands, runtime requirements, installation and X11/Wayland acceptance checks.

From the repository root, prepare JS production dependencies with `(cd sidecars/spider-host-js && npm ci --omit=dev)`. Build the native bundle with:

```bash
cd apps/desktop-flutter
flutter build linux --release --dart-define=APP_VERSION=0.1.0
xvfb-run -a flutter test
```

The bundle is `build/linux/x64/release/bundle`. Use the current pubspec version when it differs from the example. The packager `scripts/package_linux.py` writes both formats and checksums/metadata into `dist/linux`; Node is bundled, while Python 3 and JDK 17+ remain system dependencies for corresponding sources. Tracked JVM jars are used without a Linux JVM build script.

Linux CI only retains artifacts; manual Linux Release dispatch publishes only when `publish_release=true` and smoke succeeds. Reusing a release preserves its notes/prerelease state and Windows assets. Linux release metadata is prefixed `linux-` to avoid collisions; local artifact metadata names are unchanged.
