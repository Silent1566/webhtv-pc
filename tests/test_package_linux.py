"""Contract tests: controlled tools are not native/AppImage validation."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import stat
import struct
import sys
import tarfile
import tempfile
import unittest
import zipfile
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/package_linux.py"


def make_python_fixture(directory, lock_path, executable=None):
    """Genuine ZIP/lock fixture; ELF headers do not claim a native Python runtime."""
    lock = json.loads((SCRIPT.parent / "python-runtime-linux.lock.json").read_text())
    elf = bytearray(64)
    elf[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", elf, 18, 62)
    elf = bytes(elf)
    files = {"bin/python3": executable or elf, "lib/libpython3.14.so.1.0": elf,
             "lib/python3.14/LICENSE.txt": b"CPython license", "lib/python3.14/os.py": b"# os",
             "lib/python3.14/encodings/__init__.py": b"# encodings"}
    site = "lib/python3.14/site-packages/"
    for name in ("requests", "Crypto", "lxml", "bs4"):
        files[site + name + "/__init__.py"] = b"# fixture"
    files[site + "lxml/etree.cpython-314-x86_64-linux-gnu.so"] = elf
    files[site + "Crypto/Cipher/_raw_aes.abi3.so"] = elf
    for package in lock["packages"]:
        prefix = site + package["name"].replace("-", "_") + "-" + package["version"] + ".dist-info/"
        files[prefix + "METADATA"] = f'Name: {package["name"]}\nVersion: {package["version"]}\n'.encode()
        interpreter, abi, platforms = package["filename"][:-4].split("-")[-3:]
        files[prefix + "WHEEL"] = ("Wheel-Version: 1.0\n" + "".join(
            f"Tag: {interpreter}-{abi}-{platform}\n" for platform in platforms.split("."))).encode()
        files[prefix + "RECORD"] = b"fixture"
        files[prefix + "licenses/LICENSE"] = b"license"
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / "python-runtime.zip"
    with zipfile.ZipFile(archive, "w") as stream:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.external_attr = (stat.S_IFREG | 0o600) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            stream.writestr(info, data)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = {"schemaVersion": 1, "platform": "linux-x64", "pythonVersion": "3.14.10",
                "archive": "python-runtime.zip", "archiveSha256": digest,
                "probeModules": ["requests", "Crypto", "lxml", "bs4"],
                "packages": [{"name": p["name"], "version": p["version"]} for p in lock["packages"]],
                "files": [{"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                          for name, data in sorted(files.items())]}
    (directory / "bundle.json").write_text(json.dumps(manifest))
    lock["assembled"] = {"archiveSha256": digest, "size": archive.stat().st_size,
                         "expandedSize": sum(map(len, files.values())), "fileCount": len(files)}
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.write_text(json.dumps(lock))
    return manifest


class PackageLinuxTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "Linux packager has not been implemented")
        spec = importlib.util.spec_from_file_location("package_linux", SCRIPT)
        self.packager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.packager)
        self.temp = tempfile.TemporaryDirectory(prefix="webhtv-package-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.packager.REPO_ROOT = self.repo
        self.bundle = self.repo / "build/bundle"
        self.bundle.mkdir(parents=True)
        self.put(self.bundle / "webhtv_pc", "#!/bin/sh\necho fake-app\n", 0o755)
        self.put(self.bundle / "lib/libflutter_linux_gtk.so", "controlled-library")
        self.put(self.bundle / "data/flutter_assets/asset", "safe-asset")
        (self.bundle / "lib/libalias.so").symlink_to("libflutter_linux_gtk.so")
        self.node = self.root / "node"
        self.put(self.node / "bin/node", "#!/bin/sh\necho v22.23.4\n", 0o755)
        self.put(self.node / "LICENSE", "Node license")
        for name in ["host.py", "webhtv_ipc.py", "webhtv_catvod.py", "base/__init__.py", "base/spider.py"]:
            self.put(self.repo / "sidecars/spider-host-python" / name, "python host")
        js = self.repo / "sidecars/spider-host-js"
        for name in ["host.js", "sandbox_worker.js", "esm_shim.js", "tvbox_globals.js"]:
            self.put(js / name, "js host")
        self.put(js / "package.json", json.dumps({"name": "host", "dependencies": {"prod": "1.0.0"}}))
        self.put(js / "package-lock.json", json.dumps({"lockfileVersion": 3, "packages": {
            "": {"dependencies": {"prod": "1.0.0"}},
            "node_modules/prod": {"version": "1.0.0", "license": "MIT"},
            "node_modules/dev": {"version": "1.0.0", "dev": True}}}))
        self.put(js / "node_modules/prod/package.json", '{"name":"prod","version":"1.0.0","license":"MIT"}')
        self.put(js / "node_modules/prod/index.js", "production module")
        self.put(js / "node_modules/prod/LICENSE", "MIT license")
        self.put(js / "node_modules/prod/fixtures/private.json", "secret")
        self.put(js / "node_modules/dev/index.js", "dev module")
        self.put(js / "manifests/spiders/private.json", "secret")
        jvm = self.repo / "sidecars/spider-host-jvm"
        jvm.mkdir(parents=True)
        with zipfile.ZipFile(jvm / "host.jar", "w") as z:
            z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\nClass-Path: lib/dep.jar\n\n")
        self.put(jvm / "lib/dep.jar", "dependency")
        self.put(jvm / "lib/THIRD-PARTY-NOTICES.md", "JVM notices")
        self.put(jvm / "lib/unreferenced.jar", "do not ship")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.native = self.root / "system/libmpv.so.2"
        self.put(self.native, "native mpv")
        self.native_child = self.root / "system/libcodec.so.1"
        self.put(self.native_child, "native codec")
        self.put(self.tools / "ldd", "#!/usr/bin/env python3\nimport sys\np=sys.argv[-1]\n" +
                 "print('libcodec.so.1 => " + str(self.native_child) + " (0x01)' if 'mpv' in p else 'libmpv.so.2 => " + str(self.native) + " (0x01)')\n", 0o755)
        self.put(self.tools / "dpkg-query", "#!/bin/sh\ncase \"$1\" in -S) echo 'libcontrolled1:amd64: ' \"$2\";; -W) printf 'libcontrolled1\t1.2.3\n';; esac\n", 0o755)
        fake_archive = "#!/usr/bin/env python3\nimport sys,tarfile\na=sys.argv[1:]\nwith tarfile.open(a[-1], 'w') as t: t.add(a[-2],arcname='.')\n"
        self.put(self.tools / "appimagetool", fake_archive, 0o755)
        self.put(self.tools / "dpkg-deb", fake_archive, 0o755)
        self.env = {"PATH": str(self.tools) + os.pathsep + os.environ["PATH"]}
        self.python_runtime = self.repo / "runtime/python"
        self.python_lock = self.root / "fixture.lock.json"
        make_python_fixture(self.python_runtime, self.python_lock)
        sys.path.insert(0, str(SCRIPT.parent))
        try:
            import prepare_python_runtime_linux as validator
        finally:
            sys.path.pop(0)
        lock_patch = patch.object(validator, "DEFAULT_LOCK", self.python_lock)
        lock_patch.start()
        self.addCleanup(lock_patch.stop)
        self.validator = validator
        self.output = self.root / "output"
        self.args = ["--build-dir", str(self.bundle), "--output-dir", str(self.output),
                     "--version", "1.2.3", "--node-runtime-dir", str(self.node),
                     "--commit", "abc123full", "--short-commit", "abc123", "--build-number", "9",
                     "--built-at", "2026-12-03T00:00:00Z", "--flutter-version", "3.41.5"]

    def test_python_runtime_cli_default(self):
        args = self.packager.parse_arguments(["--version", "1.2.3"])
        self.assertTrue(hasattr(args, "python_runtime_dir"), "missing --python-runtime-dir")
        self.assertEqual(args.python_runtime_dir, str(self.repo / "runtime/python"))

    def test_missing_python_runtime_prevents_publish(self):
        (self.python_runtime / "python-runtime.zip").unlink()
        self.run_package(success=False)
        self.assertFalse(self.output.exists())

    def test_python_tamper_wrong_platform_pollution_links_and_overlap_rejected(self):
        manifest = make_python_fixture(self.python_runtime, self.python_lock)
        archive = self.python_runtime / "python-runtime.zip"
        archive.write_bytes(archive.read_bytes() + b"tamper")
        self.run_package(success=False)
        manifest = make_python_fixture(self.python_runtime, self.python_lock)
        manifest["platform"] = "windows-x64"
        (self.python_runtime / "bundle.json").write_text(json.dumps(manifest))
        self.run_package(success=False)
        make_python_fixture(self.python_runtime, self.python_lock)
        self.put(self.python_runtime / "config.json", "private")
        self.run_package(success=False)
        (self.python_runtime / "config.json").unlink()
        external = self.root / "external-runtime.zip"
        archive.rename(external)
        archive.symlink_to(external)
        self.run_package(success=False)
        archive.unlink()
        make_python_fixture(self.python_runtime, self.python_lock)
        for output in (self.python_runtime, self.python_runtime / "out"):
            self.run_package(["--output-dir", str(output)], success=False)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.validator.validate_bundle(self.python_runtime)["platform"], "linux-x64")

    def test_user_spiders_config_and_database_are_not_packaged(self):
        for name in ("config/settings.json", "configs.json", "settings.json", "webhtv-pc.sqlite3",
                     "webhtv-pc.sqlite3-wal", "webhtv-pc.sqlite3-shm", "spiders/user.py"):
            self.put(self.bundle / "data" / name, "private user data")
        self.run_package()
        stem = "webhtv-pc-1.2.3-dev-linux-x64"
        for payload in (self.extracted(stem + ".AppImage"), self.extracted(stem + ".deb") / "opt/webhtv-pc"):
            for name in ("config", "configs.json", "settings.json", "webhtv-pc.sqlite3",
                         "webhtv-pc.sqlite3-wal", "webhtv-pc.sqlite3-shm", "spiders"):
                self.assertFalse((payload / "data" / name).exists(), name)
            self.assertTrue((payload / "data/flutter_assets/asset").exists())

    def test_explicit_python_runtime_directory_is_copied(self):
        explicit = self.root / "explicit-python"
        shutil.copytree(self.python_runtime, explicit)
        self.run_package(["--python-runtime-dir", str(explicit), "--formats", "deb"])
        payload = self.extracted("webhtv-pc-1.2.3-dev-linux-x64.deb") / "opt/webhtv-pc"
        self.assertEqual(self.validator.validate_bundle(payload / "runtime/python"),
                         self.validator.validate_bundle(explicit))

    def put(self, path, text, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)

    def run_package(self, extra=(), success=True):
        with patch.dict(os.environ, self.env):
            code = self.packager.main(self.args + list(extra))
        self.assertEqual(code, 0 if success else 1)
        return code

    def extracted(self, name):
        target = self.root / (name + "-extract")
        with tarfile.open(self.output / name) as t:
            t.extractall(target, filter="data")
        return target

    def test_both_formats_metadata_and_content_contract(self):
        self.run_package()
        stem = "webhtv-pc-1.2.3-dev-linux-x64"
        info = json.loads((self.output / "release-info.json").read_text())
        self.assertEqual((info["schema"], info["platform"], info["arch"], info["build"]), (1, "linux", "x64", 9))
        self.assertEqual(info["channel"], "dev")
        self.assertEqual(info["commit"], "abc123full")
        self.assertEqual(info["builtAt"], "2026-12-03T00:00:00Z")
        self.assertEqual(info["flutter"], "3.41.5")
        self.assertEqual(info["signature"], {"status": "unsigned", "subject": None})
        self.assertEqual(info["runtimes"]["requiresLocal"], ["JDK 17+"])
        self.assertEqual(info["runtimes"]["bundled"][0]["path"], "runtime/node/node")
        python = next(item for item in info["runtimes"]["bundled"] if item["id"] == "python")
        self.assertEqual(python["version"], "3.14.10")
        self.assertEqual(python["path"], "runtime/python/python-runtime.zip")
        self.assertEqual(python["sha256"], hashlib.sha256((self.python_runtime / "python-runtime.zip").read_bytes()).hexdigest())
        self.assertEqual([a["name"] for a in info["assets"]], [stem + ".AppImage", stem + ".deb"])
        for asset in info["assets"]:
            p = self.output / asset["name"]
            self.assertEqual(asset["sha256"], hashlib.sha256(p.read_bytes()).hexdigest())
            self.assertEqual(asset["size"], p.stat().st_size)
            self.assertIn(asset["sha256"] + "  " + asset["name"], (self.output / "SHA256SUMS.txt").read_text())
        app = self.extracted(stem + ".AppImage")
        self.assertTrue((app / "webhtv_pc").stat().st_mode & 0o111)
        self.assertTrue((app / "runtime/node/node").stat().st_mode & 0o111)
        self.assertTrue((app / "lib/libalias.so").is_symlink())
        self.assertEqual(os.readlink(app / "lib/libalias.so"), "libflutter_linux_gtk.so")
        for name in ["sidecars/spider-host-jvm/lib/dep.jar", "sidecars/spider-host-jvm/lib/THIRD-PARTY-NOTICES.md",
                     "sidecars/spider-host-js/package-lock.json", "sidecars/spider-host-js/node_modules/prod/LICENSE",
                     "runtime/node/LICENSE", "BUILD-INFO.json", "THIRD-PARTY-NOTICES.txt"]:
            self.assertTrue((app / name).is_file(), name)
        for name in ["sidecars/spider-host-jvm/lib/unreferenced.jar", "sidecars/spider-host-js/node_modules/dev",
                     "sidecars/spider-host-js/node_modules/prod/fixtures", "sidecars/spider-host-js/manifests"]:
            self.assertFalse((app / name).exists(), name)
        self.assertTrue((app / "lib/libmpv.so.2").is_file())
        self.assertTrue((app / "lib/libcodec.so.1").is_file(), "transitive non-base native dependency missing")
        env = os.environ.copy()
        env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        result = subprocess.run([str(app / "AppRun")], cwd="/", env=env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "fake-app"))
        deb = self.extracted(stem + ".deb")
        self.assertTrue((deb / "opt/webhtv-pc/sidecars/spider-host-python/host.py").exists())
        self.assertIn("/opt/webhtv-pc", (deb / "usr/bin/webhtv-pc").read_text())
        control = (deb / "DEBIAN/control").read_text()
        self.assertIn("Architecture: amd64", control)
        self.assertNotIn("python3", control)
        self.assertIn("Recommends: openjdk-17-jre-headless", control)
        for payload in (app, deb / "opt/webhtv-pc"):
            for name in ("python-runtime.zip", "bundle.json"):
                self.assertEqual((payload / "runtime/python" / name).read_bytes(), (self.python_runtime / name).read_bytes())
            self.validator.validate_bundle(payload / "runtime/python")
        self.assertIn("Version: 1.2.3~dev-9", control)
        self.assertIn("libcontrolled1", control)
        self.assertTrue((deb / "usr/share/applications/webhtv-pc.desktop").is_file())

    def test_deb_depends_on_discovered_jammy_mpv_owner_without_duplicates(self):
        self.native = self.native.rename(self.native.with_name("libmpv.so.1"))
        self.put(self.tools / "ldd", "#!/usr/bin/env python3\nimport sys\np=sys.argv[-1]\n" +
                 "print('libcodec.so.1 => " + str(self.native_child) + " (0x01)' if 'mpv' in p else 'libmpv.so.1 => " + str(self.native) + " (0x01)')\n", 0o755)
        self.put(self.tools / "dpkg-query", "#!/usr/bin/env python3\nimport sys\na=sys.argv[1:]\n" +
                 "owner='libmpv1' if 'mpv' in a[-1] else 'libgtk-3-0'\n" +
                 "version='0.34.1-1ubuntu3' if owner=='libmpv1' else '3.24.33-1ubuntu2'\n" +
                 "print(owner+':amd64: '+a[-1] if a[0]=='-S' else owner+'\\t'+version)\n", 0o755)
        self.run_package(["--formats", "deb"])
        deb = self.extracted("webhtv-pc-1.2.3-dev-linux-x64.deb")
        control = (deb / "DEBIAN/control").read_text()
        depends = next(line.removeprefix("Depends: ") for line in control.splitlines() if line.startswith("Depends: "))
        self.assertNotIn("libmpv2", depends)
        self.assertEqual(depends.split(", "), ["libgtk-3-0 (>= 3.24.33-1ubuntu2)", "libmpv1 (>= 0.34.1-1ubuntu3)"])

    def test_player_library_remains_mandatory(self):
        self.put(self.tools / "ldd", "#!/bin/sh\nexit 0\n", 0o755)
        self.put(self.tools / "ldconfig", "#!/bin/sh\nexit 0\n", 0o755)
        self.run_package(["--formats", "deb"], success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_single_format_stable_and_beta_names(self):
        for channel, suffix in [("stable", ""), ("beta", "-beta")]:
            with self.subTest(channel=channel):
                self.run_package(["--formats", "deb", "--channel", channel])
                self.assertTrue((self.output / ("webhtv-pc-1.2.3" + suffix + "-linux-x64.deb")).exists())
                self.assertEqual(len(json.loads((self.output / "release-info.json").read_text())["assets"]), 1)

    def test_missing_inputs_preserve_existing_output(self):
        sentinel = self.output / "webhtv-pc-1.2.3-dev-linux-x64.deb"
        self.put(sentinel, "existing artifact")
        targets = [self.bundle / "webhtv_pc", self.node / "LICENSE",
                   self.repo / "sidecars/spider-host-js/node_modules/prod/index.js",
                   self.repo / "sidecars/spider-host-jvm/lib/dep.jar",
                   self.repo / "sidecars/spider-host-jvm/lib/THIRD-PARTY-NOTICES.md"]
        # Removing the installed production package, not an arbitrary JS module, breaks staging.
        targets[2] = self.repo / "sidecars/spider-host-js/node_modules/prod"
        for target in targets:
            with self.subTest(target=str(target)):
                backup = target.with_name(target.name + ".test-backup")
                target.rename(backup)
                try:
                    self.run_package(success=False)
                    self.assertEqual(sentinel.read_text(), "existing artifact")
                finally:
                    backup.rename(target)

    def test_output_overlap_and_invalid_inputs_rejected_without_deletion(self):
        for output in [self.repo, self.bundle, self.bundle / "nested", self.node, self.root, Path("/")]:
            with self.subTest(output=str(output)):
                self.run_package(["--output-dir", str(output)], success=False)
                self.assertTrue((self.bundle / "webhtv_pc").exists())
        for extra in [["--version", "../escape"], ["--version", "1.0\nDepends: evil"], ["--build-number", "0"],
                      ["--node-version", "../../escape"], ["--formats", "rpm"], ["--notes-file", str(self.root / "missing")]]:
            with self.subTest(extra=extra):
                self.run_package(extra, success=False)

    def test_output_symlink_and_collision_rejected(self):
        self.output.symlink_to(self.bundle, target_is_directory=True)
        self.run_package(success=False)
        self.output.unlink()
        self.output.mkdir()
        outside = self.root / "untouched"
        self.put(outside, "preserve")
        (self.output / "release-info.json").symlink_to(outside)
        self.run_package(success=False)
        self.assertEqual(outside.read_text(), "preserve")

    def test_external_or_absolute_bundle_symlinks_rejected(self):
        for target in [str(self.node / "LICENSE"), "../../../../node/LICENSE"]:
            with self.subTest(target=target):
                link = self.bundle / "data/escape"
                link.symlink_to(target)
                try:
                    self.run_package(success=False)
                finally:
                    link.unlink()

    def test_untrusted_jvm_classpath_rejected(self):
        with zipfile.ZipFile(self.repo / "sidecars/spider-host-jvm/host.jar", "w") as z:
            z.writestr("META-INF/MANIFEST.MF", "Class-Path: ../../private.jar\n")
        self.run_package(success=False)

    def test_missing_native_dependency_fails_without_publishing(self):
        self.put(self.tools / "ldd", "#!/bin/sh\necho 'libmpv.so.2 => not found'\n", 0o755)
        self.run_package(success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_archive_traversal_links_and_special_files_rejected(self):
        for kind in ["parent", "absolute", "symlink", "hardlink", "fifo", "chain"]:
            with self.subTest(kind=kind):
                archive = self.root / (kind + ".tar.xz")
                with tarfile.open(archive, "w:xz") as t:
                    member = tarfile.TarInfo({"parent": "../escape", "absolute": "/escape"}.get(kind, "node/bin/node"))
                    if kind in ["symlink", "chain"]:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "../../../escape"
                    elif kind == "hardlink":
                        member.type = tarfile.LNKTYPE
                        member.linkname = "../../escape"
                    elif kind == "fifo":
                        member.type = tarfile.FIFOTYPE
                    t.addfile(member)
                with self.assertRaises(self.packager.PackageError):
                    self.packager.extract_node_archive(archive, self.root / (kind + "-out"))

    def test_safe_node_archive_and_checksum_verification(self):
        archive = self.root / "node.tar.xz"
        with tarfile.open(archive, "w:xz") as t:
            for name, text, mode in [("node-v22.23.4-linux-x64/bin/node", "binary", 0o755),
                                     ("node-v22.23.4-linux-x64/LICENSE", "license", 0o644)]:
                m = tarfile.TarInfo(name)
                m.size = len(text)
                m.mode = mode
                t.addfile(m, io.BytesIO(text.encode()))
        dest = self.root / "extracted-node"
        self.packager.extract_node_archive(archive, dest)
        self.assertTrue((dest / "node-v22.23.4-linux-x64/bin/node").stat().st_mode & 0o111)
        payload = archive.read_bytes()
        checksum = hashlib.sha256(payload).hexdigest()
        def download(url, path):
            Path(path).write_bytes((checksum + "  node-v22.23.4-linux-x64.tar.xz\n").encode() if url.endswith("SHASUMS256.txt") else payload)
        with patch.object(self.packager, "download", side_effect=download):
            runtime = self.packager.resolve_node("v22.23.4", None, self.root / "download")
        self.assertTrue((runtime / "bin/node").exists())
        with patch.object(self.packager, "download", side_effect=lambda url, path: Path(path).write_bytes(b"corrupt")):
            with self.assertRaises(self.packager.PackageError):
                self.packager.resolve_node("v22.23.4", None, self.root / "bad-download")

    def test_safe_upstream_node_symlinks_are_preserved(self):
        archive = self.root / "upstream-layout.tar.xz"
        with tarfile.open(archive, "w:xz") as t:
            for name in ["node/bin/node", "node/lib/node_modules/npm/bin/npm-cli.js", "node/LICENSE"]:
                m = tarfile.TarInfo(name)
                m.size = 1
                t.addfile(m, io.BytesIO(b"x"))
            m = tarfile.TarInfo("node/bin/npm")
            m.type = tarfile.SYMTYPE
            m.linkname = "../lib/node_modules/npm/bin/npm-cli.js"
            t.addfile(m)
        dest = self.root / "safe-upstream"
        self.packager.extract_node_archive(archive, dest)
        self.assertTrue((dest / "node/bin/npm").is_symlink())
        self.assertEqual((dest / "node/bin/npm").read_text(), "x")

    def test_symlink_to_excluded_fixture_rejected(self):
        self.put(self.bundle / "data/fixtures/secret", "secret")
        (self.bundle / "data/alias").symlink_to("fixtures/secret")
        self.run_package(success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_symlinked_sidecar_root_rejected(self):
        source = self.repo / "sidecars/spider-host-python"
        external = self.root / "external-host"
        source.rename(external)
        source.symlink_to(external, target_is_directory=True)
        self.run_package(success=False)

    def test_bundle_inventory_and_private_residue_excluded(self):
        self.put(self.bundle / "data/.env", "SECRET=x")
        self.put(self.bundle / "data/cookies.txt", "private cookie")
        self.run_package(["--formats", "deb"])
        deb = self.extracted("webhtv-pc-1.2.3-dev-linux-x64.deb")
        payload = deb / "opt/webhtv-pc"
        self.assertFalse((payload / "data/.env").exists())
        self.assertFalse((payload / "data/cookies.txt").exists())
        inventory = json.loads((payload / "BUILD-INFO.json").read_text())
        entries = {entry["path"]: entry for entry in inventory["bundleLibraries"]}
        self.assertEqual(entries["lib/libflutter_linux_gtk.so"]["sha256"], hashlib.sha256(b"controlled-library").hexdigest())

    @unittest.skipUnless(os.environ.get("WEBHTV_TEST_APPIMAGETOOL"), "set WEBHTV_TEST_APPIMAGETOOL for real AppImage tool test")
    def test_real_appimage_roundtrip_with_controlled_payload(self):
        tool = os.environ["WEBHTV_TEST_APPIMAGETOOL"]
        self.run_package(["--formats", "appimage", "--appimagetool", tool])
        image = self.output / "webhtv-pc-1.2.3-dev-linux-x64.AppImage"
        extracted = self.root / "real-appimage"
        extracted.mkdir()
        result = subprocess.run([str(image), "--appimage-extract"], cwd=extracted, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        appdir = extracted / "squashfs-root"
        self.assertTrue((appdir / "lib/libcodec.so.1").exists())
        self.assertTrue((appdir / "runtime/node/node").stat().st_mode & 0o111)
        self.assertTrue((appdir / "lib/libalias.so").is_symlink())
        env = os.environ.copy()
        env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        result = subprocess.run([str(image)], cwd="/", env=env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "fake-app"), result.stderr)

    def test_symlinked_external_js_package_rejected(self):
        source = self.repo / "sidecars/spider-host-js/node_modules/prod"
        external = self.root / "external-js"
        source.rename(external)
        source.symlink_to(external, target_is_directory=True)
        self.run_package(success=False)

    def test_external_node_bin_parent_symlink_rejected_without_publish(self):
        external = self.root / "external-node-bin"
        (self.node / "bin").rename(external)
        (self.node / "bin").symlink_to(external, target_is_directory=True)
        self.put(self.output / "release-info.json", "old metadata")
        self.run_package(["--formats", "deb"], success=False)
        self.assertEqual((self.output / "release-info.json").read_text(), "old metadata")
        self.assertFalse((self.output / "webhtv-pc-1.2.3-dev-linux-x64.deb").exists())
        with self.assertRaises(self.packager.PackageError):
            self.packager.resolve_node("v22.23.4", self.node, self.root / "unused")

    def test_external_python_base_parent_symlink_rejected_without_copy(self):
        host = self.repo / "sidecars/spider-host-python"
        external = self.root / "external-python-base"
        (host / "base").rename(external)
        self.put(external / "__init__.py", "SECRET_EXTERNAL_TARGET")
        (host / "base").symlink_to(external, target_is_directory=True)
        payload = self.root / "probe-payload"
        with self.assertRaises(self.packager.PackageError):
            self.packager.stage_sidecars(payload)
        self.assertFalse((payload / "sidecars/spider-host-python/base/__init__.py").exists())
        self.run_package(["--formats", "deb"], success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_external_jvm_lib_parent_symlink_rejected_without_publish(self):
        host = self.repo / "sidecars/spider-host-jvm"
        external = self.root / "external-jvm-lib"
        (host / "lib").rename(external)
        (host / "lib").symlink_to(external, target_is_directory=True)
        self.run_package(["--formats", "deb"], success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_external_runtime_license_link_rejected(self):
        license_file = self.node / "LICENSE"
        external = self.root / "external-license"
        license_file.rename(external)
        license_file.symlink_to(external)
        self.run_package(["--formats", "deb"], success=False)
        self.assertFalse((self.output / "release-info.json").exists())

    def test_safe_relative_internal_node_and_license_links_work(self):
        (self.node / "bin").rename(self.node / "actual-bin")
        (self.node / "bin").symlink_to("actual-bin", target_is_directory=True)
        (self.node / "LICENSE").rename(self.node / "NODE-LICENSE")
        (self.node / "LICENSE").symlink_to("NODE-LICENSE")
        self.run_package(["--formats", "deb"])
        deb = self.extracted("webhtv-pc-1.2.3-dev-linux-x64.deb")
        self.assertEqual((deb / "opt/webhtv-pc/runtime/node/LICENSE").read_text(), "Node license")
        self.assertTrue((deb / "opt/webhtv-pc/runtime/node/node").stat().st_mode & 0o111)

    def test_safe_relative_internal_bundle_directory_link_preserved(self):
        self.put(self.bundle / "data/internal/item", "asset")
        (self.bundle / "data/alias-dir").symlink_to("internal", target_is_directory=True)
        self.run_package(["--formats", "deb"])
        deb = self.extracted("webhtv-pc-1.2.3-dev-linux-x64.deb")
        alias = deb / "opt/webhtv-pc/data/alias-dir"
        self.assertTrue(alias.is_symlink())
        self.assertEqual(os.readlink(alias), "internal")
        self.assertEqual((alias / "item").read_text(), "asset")

    def test_tool_failure_keeps_all_old_artifacts(self):
        self.put(self.output / "release-info.json", "old metadata")
        self.put(self.output / "webhtv-pc-1.2.3-dev-linux-x64.AppImage", "old artifact")
        self.put(self.tools / "dpkg-deb", "#!/bin/sh\nexit 42\n", 0o755)
        self.run_package(success=False)
        self.assertEqual((self.output / "release-info.json").read_text(), "old metadata")
        self.assertEqual((self.output / "webhtv-pc-1.2.3-dev-linux-x64.AppImage").read_text(), "old artifact")

    @unittest.skipUnless(shutil.which("dpkg-deb"), "real dpkg-deb unavailable")
    def test_real_dpkg_deb_roundtrip_with_controlled_payload(self):
        # Only the dpkg-deb build/extract/control check is real; app/Node/native inputs remain fixtures.
        self.put(self.tools / "dpkg-deb", "#!/bin/sh\nexec /usr/bin/dpkg-deb \"$@\"\n", 0o755)
        self.run_package(["--formats", "deb", "--channel", "stable"])
        artifact = self.output / "webhtv-pc-1.2.3-linux-x64.deb"
        result = subprocess.run(["/usr/bin/dpkg-deb", "--field", str(artifact), "Package", "Version", "Architecture", "Depends"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Version: 1.2.3-9", result.stdout)
        dest = self.root / "real-deb"
        subprocess.run(["/usr/bin/dpkg-deb", "--extract", str(artifact), str(dest)], check=True, capture_output=True)
        self.assertTrue((dest / "opt/webhtv-pc/runtime/node/node").stat().st_mode & 0o111)
        self.assertTrue((dest / "opt/webhtv-pc/lib/libalias.so").is_symlink())
        self.assertEqual((dest / "opt/webhtv-pc/sidecars/spider-host-jvm/lib/dep.jar").read_text(), "dependency")


class LinuxCMakePythonTests(unittest.TestCase):
    def test_production_install_preserves_old_bundle_on_tamper_and_cleans_on_success(self):
        source = (SCRIPT.parents[1] / "apps/desktop-flutter/linux/CMakeLists.txt").read_text()
        install_section = source.split("# === Installation ===", 1)[1].split("set(INSTALL_BUNDLE_DATA_DIR", 1)[0]
        with tempfile.TemporaryDirectory(prefix="webhtv-cmake-preserve-") as tmp:
            root = Path(tmp)
            runtime = root / "input/runtime/python"
            runtime.mkdir(parents=True)
            for name in ("bundle.json", "python-runtime.zip"):
                shutil.copyfile(SCRIPT.parents[1] / "runtime/python" / name, runtime / name)
            project = root / "source"
            project.mkdir()
            (project / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.13)\nproject(preserve_bundle NONE)\n'
                + f'set(WEBHTV_REPO_ROOT "{SCRIPT.parents[1]}")\n' + install_section)
            build = root / "build"
            configured = subprocess.run(["cmake", "-S", str(project), "-B", str(build),
                                         f"-DWEBHTV_PYTHON_RUNTIME_DIR={runtime}"], capture_output=True, text=True)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            install_args = ["cmake", "--install", str(build)]
            installed = subprocess.run(install_args, capture_output=True, text=True)
            self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
            bundle = build / "bundle"
            for name in ("bundle.json", "python-runtime.zip"):
                self.assertEqual((bundle / "runtime/python" / name).read_bytes(), (runtime / name).read_bytes())
            (bundle / "old-data").mkdir()
            (bundle / "old-data/state.txt").write_text("existing user-independent build data")
            (bundle / "stale.txt").write_text("must be removed only after validation succeeds")

            def fingerprint():
                return {path.relative_to(bundle).as_posix():
                        ("dir",) if path.is_dir() else ("file", path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
                        for path in sorted(bundle.rglob("*"))}

            before = fingerprint()
            with (runtime / "python-runtime.zip").open("ab") as output:
                output.write(b"tamper")
            invalid = subprocess.run(install_args, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("Invalid or missing offline Linux Python bundle", invalid.stdout + invalid.stderr)
            self.assertEqual(fingerprint(), before, "Failed validation must preserve every old bundle path, size, and SHA256")
            print("TAMPER_REJECTED_OLD_BUNDLE_PRESERVED", json.dumps(before, sort_keys=True))
            shutil.copyfile(SCRIPT.parents[1] / "runtime/python/python-runtime.zip", runtime / "python-runtime.zip")
            repaired = subprocess.run(install_args, capture_output=True, text=True)
            self.assertEqual(repaired.returncode, 0, repaired.stdout + repaired.stderr)
            self.assertFalse((bundle / "stale.txt").exists())
            self.assertFalse((bundle / "old-data").exists())
            for name in ("bundle.json", "python-runtime.zip"):
                self.assertEqual((bundle / "runtime/python" / name).read_bytes(), (runtime / name).read_bytes())
            print("VALID_INPUT_CLEANUP_AND_INSTALL_PASS", json.dumps(fingerprint(), sort_keys=True))

    def test_cmake_requires_bundle_and_installs_only_verified_files(self):
        source = (SCRIPT.parents[1] / "apps/desktop-flutter/linux/CMakeLists.txt").read_text()
        self.assertIn("# === Bundled offline Python ===", source)
        block = source.split("# === Installation ===", 1)[1].split("set(INSTALL_BUNDLE_DATA_DIR", 1)[0]
        with tempfile.TemporaryDirectory(prefix="webhtv-cmake-python-") as tmp:
            root = Path(tmp)
            runtime = root / "runtime/python"
            project = root / "source"
            project.mkdir()
            (project / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.13)\nproject(python_gate NONE)\n'
                + f'set(WEBHTV_REPO_ROOT "{SCRIPT.parents[1]}")\n' + block)
            build = root / "build"
            args = ["cmake", "-S", str(project), "-B", str(build),
                    f"-DWEBHTV_PYTHON_RUNTIME_DIR={runtime}", f"-DCMAKE_INSTALL_PREFIX={root / 'installed'}"]
            missing = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("Invalid or missing offline Linux Python bundle", missing.stdout + missing.stderr)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copyfile(SCRIPT.parent / "prepare_python_runtime_linux.py", scripts / "prepare_python_runtime_linux.py")
            make_python_fixture(runtime, scripts / "python-runtime-linux.lock.json")
            (project / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.13)\nproject(python_gate NONE)\n'
                + f'set(WEBHTV_REPO_ROOT "{root}")\n' + block)
            valid = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
            install = subprocess.run(["cmake", "--install", str(build)], capture_output=True, text=True)
            self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
            for name in ("bundle.json", "python-runtime.zip"):
                self.assertEqual((root / "installed/runtime/python" / name).read_bytes(), (runtime / name).read_bytes())
            with (runtime / "python-runtime.zip").open("ab") as output:
                output.write(b"tamper")
            invalid = subprocess.run(["cmake", "--install", str(build)], capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("Invalid or missing offline Linux Python bundle", invalid.stdout + invalid.stderr)


if __name__ == "__main__":
    unittest.main()
