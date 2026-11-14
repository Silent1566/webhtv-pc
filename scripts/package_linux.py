#!/usr/bin/env python3
"""Build Linux x86_64 AppImage/deb artifacts from a trusted Flutter bundle.

Python 3 standard library only. Build on Ubuntu 22.04 for that glibc baseline;
AppImage still requires compatible glibc, display/graphics drivers, and optional
system Python 3 / JDK 17+ for those sidecars. Never run on untrusted ELF inputs:
ldd is a native build-tool inspection, not an executable sandbox.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import posixpath
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

REPO_ROOT = Path(__file__).resolve().parents[1]
SIDECAR_FILES = {
    "spider-host-python": ["host.py", "webhtv_ipc.py", "webhtv_catvod.py", "base/__init__.py", "base/spider.py"],
    "spider-host-js": ["host.js", "sandbox_worker.js", "esm_shim.js", "tvbox_globals.js", "package.json", "package-lock.json"],
    "spider-host-jvm": ["host.jar", "lib/THIRD-PARTY-NOTICES.md"],
}
EXCLUDED = {"fixtures", "manifests", "spiders", "test", "tests", "__pycache__", ".git", ".cache", "logs", "user-data", "credentials", ".env", "cookies.txt", "credentials.json"}
BASE_LIBRARIES = re.compile(r"^(?:ld-linux.*|lib(?:c|m|dl|pthread|rt|resolv|util|nss_[^.]+)\.so(?:\..*)?)$")


class PackageError(Exception):
    pass


def require_file(path):
    if not path.is_file():
        raise PackageError(f"Missing required file: {path}")


def hash_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def write_text(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755 if executable else 0o644)


def write_json(path, value):
    write_text(path, json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def relative_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or ".." in path.parts or "\\" in name:
        raise PackageError(f"Unsafe relative path: {name}")
    return Path(*path.parts)


def validate_tree(source, boundary):
    source_path = Path(os.path.abspath(source))
    boundary_path = Path(os.path.abspath(boundary))
    try:
        contained = source_path.is_relative_to(boundary_path) and source.resolve(strict=True).is_relative_to(boundary.resolve(strict=True))
    except (OSError, RuntimeError) as error:
        raise PackageError(f"Unresolvable input: {source}: {error}") from error
    if not contained:
        raise PackageError(f"Input resolves outside boundary: {source} (boundary {boundary})")
    for ancestor in [source_path, *source_path.parents]:
        if not ancestor.is_relative_to(boundary_path):
            break
        if ancestor.is_symlink() and os.path.isabs(os.readlink(ancestor)):
            raise PackageError(f"Unsafe absolute symlink in input path: {ancestor}")
    if source.is_symlink():
        link = os.readlink(source)
        if os.path.isabs(link) or not source.resolve().is_relative_to(boundary.resolve()):
            raise PackageError(f"Unsafe symlink: {source} -> {link}")
        if not source.exists():
            raise PackageError(f"Dangling symlink: {source}")
    elif source.is_dir():
        for child in sorted(source.iterdir()):
            if child.name not in EXCLUDED:
                validate_tree(child, boundary)
    elif not source.is_file():
        raise PackageError(f"Unsupported or missing input: {source}")


def copy_safe(source, destination, boundary):
    validate_tree(source, boundary)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        destination.mkdir(exist_ok=True)
        for child in sorted(source.iterdir()):
            if child.name not in EXCLUDED:
                copy_safe(child, destination / child.name, boundary)
    else:
        shutil.copy2(source, destination)
        destination.chmod(stat.S_IMODE(source.stat().st_mode) & 0o777)


def extract_node_archive(archive, destination):
    # Validate all members before writing; links are created last and cannot be parents.
    with tarfile.open(archive, "r:*") as stream:
        members = stream.getmembers()
        by_name = {}
        for member in members:
            name = relative_path(member.name).as_posix()
            if name in by_name or not (member.isfile() or member.isdir() or member.issym()):
                raise PackageError(f"Unsafe Node archive member: {member.name}")
            by_name[name] = member
        for name, member in by_name.items():
            if any(by_name.get(parent.as_posix()) and by_name[parent.as_posix()].issym()
                   for parent in PurePosixPath(name).parents):
                raise PackageError(f"Node archive member traverses symlink: {name}")
            if member.issym():
                if PurePosixPath(member.linkname).is_absolute() or "\\" in member.linkname:
                    raise PackageError(f"Unsafe Node archive link: {name}")
                link_target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
                relative_path(link_target)
                if link_target not in by_name or by_name[link_target].issym():
                    raise PackageError(f"Dangling or chained Node archive link: {name}")
        if any(p.is_symlink() for p in [destination, *destination.parents]):
            raise PackageError(f"Unsafe Node extraction destination: {destination}")
        destination.mkdir(parents=True, exist_ok=False)
        for name, member in by_name.items():
            target = destination / name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
        for name, member in by_name.items():
            if member.issym():
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)


def download(url, path):
    with urllib.request.urlopen(url, timeout=60) as response, Path(path).open("wb") as output:
        shutil.copyfileobj(response, output)


def resolve_node(version, runtime_dir, work):
    if runtime_dir:
        runtime = Path(runtime_dir).absolute()
    else:
        work.mkdir(parents=True, exist_ok=True)
        filename = f"node-{version}-linux-x64.tar.xz"
        base = f"https://nodejs.org/dist/{version}/"
        checksums = work / "SHASUMS256.txt"
        archive = work / filename
        download(base + "SHASUMS256.txt", checksums)
        matches = re.findall(r"^([0-9a-f]{64})\s+" + re.escape(filename) + r"$", checksums.read_text(), re.MULTILINE)
        if len(matches) != 1:
            raise PackageError(f"Official checksum unavailable for {filename}")
        download(base + filename, archive)
        if hash_file(archive) != matches[0]:
            raise PackageError(f"Node SHA-256 mismatch: {filename}")
        extract_node_archive(archive, work / "extracted")
        runtime = work / "extracted" / f"node-{version}-linux-x64"
    require_file(runtime / "LICENSE")
    binary = runtime / "bin/node" if (runtime / "bin/node").exists() else runtime / "node"
    require_file(binary)
    validate_tree(binary, runtime)
    validate_tree(runtime / "LICENSE", runtime)
    if not binary.stat().st_mode & 0o111:
        raise PackageError(f"Node is not executable: {binary}")
    return runtime


def command(args, env=None, allow_failure=False):
    result = subprocess.run([str(arg) for arg in args], env=env, capture_output=True, text=True)
    if result.returncode and not allow_failure:
        raise PackageError(f"Tool failed: {args[0]} (exit {result.returncode}):\n{(result.stderr or result.stdout)[-3000:]}")
    return result


def stage_sidecars(payload):
    for host, files in SIDECAR_FILES.items():
        source = REPO_ROOT / "sidecars" / host
        target = payload / "sidecars" / host
        if source.is_symlink() or source.parent.is_symlink():
            raise PackageError(f"Sidecar root must not be a symlink: {source}")
        for name in files:
            require_file(source / name)
            copy_safe(source / name, target / name, source)
    jvm = REPO_ROOT / "sidecars/spider-host-jvm"
    with zipfile.ZipFile(jvm / "host.jar") as jar:
        manifest = jar.read("META-INF/MANIFEST.MF").decode("utf-8").replace("\r\n", "\n").replace("\n ", "")
    entry = re.search(r"^Class-Path: (.+)$", manifest, re.MULTILINE)
    if not entry:
        raise PackageError("JVM host.jar has no dependency Class-Path")
    for name in entry.group(1).split():
        path = relative_path(name)
        if path.parts[0] != "lib" or path.suffix != ".jar":
            raise PackageError(f"Unexpected JVM Class-Path: {name}")
        require_file(jvm / path)
        copy_safe(jvm / path, payload / "sidecars/spider-host-jvm" / path, jvm)
    js = REPO_ROOT / "sidecars/spider-host-js"
    lock = json.loads((js / "package-lock.json").read_text())
    if lock.get("lockfileVersion") not in (2, 3) or not isinstance(lock.get("packages"), dict):
        raise PackageError("JS packaging requires a v2/v3 package-lock.json and npm ci --omit=dev")
    packages = lock["packages"]
    selected = []
    for name, details in packages.items():
        if not name or details.get("dev"):
            continue
        path = relative_path(name)
        if path.parts[0] != "node_modules" or details.get("link"):
            raise PackageError(f"Unsupported JS lock dependency: {name}")
        source = js / path
        if source.is_symlink() or any(parent.is_symlink() for parent in source.parents if parent.is_relative_to(js)):
            raise PackageError(f"JS installed package must not traverse symlinks: {source}")
        require_file(source / "package.json")
        installed = json.loads((source / "package.json").read_text())
        if installed.get("version") != details.get("version"):
            raise PackageError(f"JS dependency version differs from lock: {name}; run npm ci --omit=dev")
        selected.append(path)
    if not selected:
        raise PackageError("JS production dependencies missing from lock")
    # Copy each locked package without nested node_modules, then copy locked nested packages.
    for path in selected:
        source = js / path
        target = payload / "sidecars/spider-host-js" / path
        target.mkdir(parents=True, exist_ok=True)
        for child in sorted(source.iterdir()):
            if child.name not in EXCLUDED | {"node_modules"}:
                copy_safe(child, target / child.name, source)


def library_dependencies(path, env):
    result = command(["ldd", path], env=env, allow_failure=True)
    output = result.stdout + result.stderr
    if "not found" in output:
        raise PackageError(f"Unresolved native dependencies of {path}:\n{output[-2000:]}")
    if result.returncode and not any(text in output for text in ("not a dynamic executable", "statically linked")):
        raise PackageError(f"Cannot inspect native dependencies of {path}: {output[-2000:]}")
    dependencies = []
    for line in result.stdout.splitlines():
        match = re.match(r"\s*(\S+) => (/.*?) \(0x[0-9a-fA-F]+\)", line)
        if match:
            dependencies.append((match[1], Path(match[2])))
        else:
            match = re.match(r"\s*(/.*?) \(0x[0-9a-fA-F]+\)", line)
            if match:
                path = Path(match[1])
                dependencies.append((path.name, path))
    return dependencies


def package_owner(path):
    candidates = [path, path.resolve()]
    if str(path).startswith("/usr/lib/"):
        candidates.append(Path(str(path)[4:]))
    for candidate in candidates:
        result = command(["dpkg-query", "-S", candidate], allow_failure=True)
        for line in result.stdout.splitlines():
            if ": " in line:
                owner = line.split(": ", 1)[0].split(", ")[0]
                if re.fullmatch(r"[a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?", owner):
                    return owner
    raise PackageError(f"Cannot derive Debian package owner of native dependency: {path}")


def native_inventory(payload):
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = str(payload / "lib")
    seeds = [payload / "webhtv_pc", payload / "runtime/node/node"]
    seeds += [p for p in (payload / "lib").rglob("*") if p.is_file()]
    pending = list(seeds)
    inspected = set()
    dependencies = {}
    while pending:
        path = pending.pop()
        if path.resolve() in inspected:
            continue
        inspected.add(path.resolve())
        for name, dependency in library_dependencies(path, env):
            require_file(dependency)
            if dependency.resolve().is_relative_to(payload.resolve()):
                pending.append(dependency)
            else:
                dependencies[name] = dependency
                pending.append(dependency)
    # media-kit loads mpv via dlopen; it need not appear in ELF DT_NEEDED.
    if not any(name.startswith("libmpv.so") for name in dependencies) and not any(p.name.startswith("libmpv.so") for p in seeds):
        cache = command(["ldconfig", "-p"]).stdout
        match = re.search(r"^\s*(libmpv\.so\.\d+) .*x86-64.* => (.+)$", cache, re.MULTILINE)
        if not match:
            raise PackageError("libmpv native player dependency missing; install libmpv-dev")
        name, value = match.groups()
        dependencies[name] = Path(value)
        pending = [Path(value)]
        while pending:
            path = pending.pop()
            if path.resolve() in inspected:
                continue
            inspected.add(path.resolve())
            for soname, dependency in library_dependencies(path, env):
                require_file(dependency)
                dependencies[soname] = dependency
                pending.append(dependency)
    owners = {package_owner(path) for path in dependencies.values()}
    packages = []
    for owner in sorted(owners):
        result = command(["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n", owner])
        fields = result.stdout.strip().split("\t")
        if len(fields) != 2:
            raise PackageError(f"Cannot determine native library version: {owner}")
        name, version = fields
        packages.append({"package": name.split(":")[0], "version": version})
    return dependencies, packages


def notices(payload, native_packages):
    sections = ["WebHTV PC Linux distribution", "Node: runtime/node/LICENSE", "JVM: sidecars/spider-host-jvm/lib/THIRD-PARTY-NOTICES.md", "JS: package licenses preserved in sidecars/spider-host-js/node_modules", "Native package versions and library hashes: BUILD-INFO.json"]
    for package in native_packages:
        name = package["package"]
        copyright_file = Path("/usr/share/doc") / name / "copyright"
        if copyright_file.is_file():
            target = payload / "licenses/native" / (name + ".copyright")
            # System package documentation may be an absolute distro symlink.
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(copyright_file, target)
            sections.append(f"{name}: licenses/native/{name}.copyright")
    write_text(payload / "THIRD-PARTY-NOTICES.txt", "\n".join(sections) + "\n")


def stage_payload(bundle, runtime, payload):
    payload.mkdir()
    for name in ["webhtv_pc", "lib", "data"]:
        copy_safe(bundle / name, payload / name, bundle)
    stage_sidecars(payload)
    binary = runtime / "bin/node" if (runtime / "bin/node").exists() else runtime / "node"
    # A provided relative Node symlink is validated, then flattened because only Node is shipped.
    (payload / "runtime/node").mkdir(parents=True)
    shutil.copy2(binary, payload / "runtime/node/node")
    shutil.copyfile(runtime / "LICENSE", payload / "runtime/node/LICENSE")
    validate_tree(payload, payload)
    result = command([payload / "runtime/node/node", "--version"])
    return result.stdout.strip()


def desktop_file():
    return "[Desktop Entry]\nType=Application\nName=WebHTV PC\nExec=webhtv-pc\nIcon=webhtv-pc\nTerminal=false\nCategories=AudioVideo;Video;\n"


def integrate(root, appimage=False):
    asset = Path(__file__).resolve().parent / "linux/webhtv-pc.svg"
    require_file(asset)
    desktop = root / "webhtv-pc.desktop" if appimage else root / "usr/share/applications/webhtv-pc.desktop"
    write_text(desktop, desktop_file())
    icon = root / "webhtv-pc.svg" if appimage else root / "usr/share/icons/hicolor/scalable/apps/webhtv-pc.svg"
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(asset, icon)
    if appimage:
        (root / ".DirIcon").symlink_to("webhtv-pc.svg")
        write_text(root / "AppRun", '#!/bin/sh\nset -eu\nAPPDIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)\nexport LD_LIBRARY_PATH="$APPDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\ncd "$APPDIR"\nexec "$APPDIR/webhtv_pc" "$@"\n', True)
    else:
        write_text(root / "usr/bin/webhtv-pc", '#!/bin/sh\nset -eu\ncd /opt/webhtv-pc\nexec /opt/webhtv-pc/webhtv_pc "$@"\n', True)


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default=str(REPO_ROOT / "apps/desktop-flutter/build/linux/x64/release/bundle"))
    parser.add_argument("--output-dir", default=str(REPO_ROOT / "dist/linux"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", default="1")
    parser.add_argument("--channel", default="dev")
    for name in ["commit", "short-commit", "built-at", "flutter-version", "tag", "notes-file", "node-runtime-dir"]:
        parser.add_argument("--" + name, default="")
    parser.add_argument("--node-version", default="v22.23.4")
    parser.add_argument("--appimagetool", default="appimagetool")
    parser.add_argument("--formats", default="appimage,deb")
    return parser.parse_args(argv)


def validate_arguments(args):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", args.version):
        raise PackageError("Version must be a safe semantic version")
    if not args.build_number.isdecimal() or int(args.build_number) < 1:
        raise PackageError("Build number must be a positive integer")
    if args.channel not in ("stable", "beta", "dev"):
        raise PackageError("Channel must be stable, beta or dev")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.node_version):
        raise PackageError("Node version must be vX.Y.Z")
    formats = args.formats.split(",")
    if not formats or len(set(formats)) != len(formats) or any(f not in ("appimage", "deb") for f in formats):
        raise PackageError("Formats must be appimage,deb or either single format")
    bundle = Path(args.build_dir).absolute()
    output = Path(args.output_dir).absolute()
    inputs = [bundle, REPO_ROOT / "sidecars"]
    if args.node_runtime_dir:
        inputs.append(Path(args.node_runtime_dir).absolute())
    if args.notes_file:
        require_file(Path(args.notes_file))
        inputs.append(Path(args.notes_file).absolute())
    if output == REPO_ROOT.resolve() or output in REPO_ROOT.resolve().parents:
        raise PackageError(f"Unsafe output directory: {output}")
    for source in inputs:
        if output.resolve().is_relative_to(source.resolve()) or source.resolve().is_relative_to(output.resolve()):
            raise PackageError(f"Output overlaps input: {output} and {source}")
    if any(p.is_symlink() for p in [output, *output.parents]):
        raise PackageError(f"Output must not traverse symlinks: {output}")
    if output.exists() and not output.is_dir():
        raise PackageError(f"Output is not a directory: {output}")
    require_file(bundle / "webhtv_pc")
    if not (bundle / "webhtv_pc").stat().st_mode & 0o111:
        raise PackageError("Flutter executable is not executable")
    for name in ["lib", "data"]:
        if not (bundle / name).is_dir():
            raise PackageError(f"Missing Flutter bundle directory: {name}")
    for name in ["webhtv_pc", "lib", "data"]:
        validate_tree(bundle / name, bundle)
    for tool in ["ldd", "dpkg-query"] + (["dpkg-deb"] if "deb" in formats else []) + ([args.appimagetool] if "appimage" in formats else []):
        if not shutil.which(tool):
            raise PackageError(f"Required packaging tool not found: {tool}")
    return bundle, output, formats


def build(args):
    bundle, output, formats = validate_arguments(args)
    suffix = "" if args.channel == "stable" else "-" + args.channel
    stem = f"webhtv-pc-{args.version}{suffix}-linux-x64"
    filenames = [stem + (".AppImage" if f == "appimage" else ".deb") for f in formats] + ["SHA256SUMS.txt", "release-info.json"]
    for name in filenames:
        target = output / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise PackageError(f"Unsafe output artifact: {target}")
    built_at = args.built_at or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    metadata = {"schema": 1, "product": "WebHTV PC", "version": args.version, "build": int(args.build_number),
                "channel": args.channel, "tag": args.tag or None, "commit": args.commit, "shortCommit": args.short_commit,
                "builtAt": built_at, "platform": "linux", "arch": "x64", "flutter": args.flutter_version,
                "signature": {"status": "unsigned", "subject": None},
                "integrity": {"label": "SHA-256", "complete": True, "failures": [], "unblockedFiles": 0},
                "notes": Path(args.notes_file).read_text() if args.notes_file else ""}
    # All preparation and tools run in an owned temporary directory; caller files are
    # replaced only after every selected format and all metadata have succeeded.
    with tempfile.TemporaryDirectory(prefix="webhtv-linux-") as directory:
        work = Path(directory)
        runtime = resolve_node(args.node_version, args.node_runtime_dir, work / "node-download")
        payload = work / "payload"
        node_version_text = stage_payload(bundle, runtime, payload)
        if node_version_text != args.node_version:
            raise PackageError(f"Node version mismatch: expected {args.node_version}, got {node_version_text}")
        dependencies, packages = native_inventory(payload)
        notices(payload, packages)
        inventory = dict(metadata, nativePackages=packages, nativeLibraries=[{"name": name, "sha256": hash_file(path), "bundledInAppImage": not bool(BASE_LIBRARIES.match(name))} for name, path in sorted(dependencies.items())])
        inventory["bundleLibraries"] = [{"path": path.relative_to(payload).as_posix(), "sha256": hash_file(path)}
                                        for path in sorted((payload / "lib").rglob("*")) if path.is_file()]
        write_json(payload / "BUILD-INFO.json", inventory)
        metadata["runtimes"] = {"bundledHosts": ["python", "node", "jvm"], "bundled": [{"id": "node", "version": args.node_version, "path": "runtime/node/node", "sha256": hash_file(payload / "runtime/node/node"), "fileVersion": node_version_text}], "requiresLocal": ["Python 3", "JDK 17+"]}
        metadata["native"] = {"packages": packages, "requiresLocal": ["compatible glibc (build baseline Ubuntu 22.04)", "X11 or Wayland", "graphics drivers"]}
        assets = []
        for format_name in formats:
            filename = stem + (".AppImage" if format_name == "appimage" else ".deb")
            artifact = work / filename
            if format_name == "appimage":
                appdir = work / "WebHTV-PC.AppDir"
                shutil.copytree(payload, appdir, symlinks=True)
                for name, source in sorted(dependencies.items()):
                    if BASE_LIBRARIES.match(name):
                        continue
                    target = appdir / "lib" / name
                    if target.exists() and hash_file(target) != hash_file(source):
                        raise PackageError(f"Conflicting native library name: {name}")
                    if not target.exists():
                        shutil.copy2(source, target)
                integrate(appdir, True)
                env = os.environ.copy()
                env.update({"ARCH": "x86_64", "APPIMAGE_EXTRACT_AND_RUN": "1"})
                command([args.appimagetool, appdir, artifact], env=env)
                require_file(artifact)
                artifact.chmod(0o755)
            else:
                deb = work / "deb"
                shutil.copytree(payload, deb / "opt/webhtv-pc", symlinks=True)
                integrate(deb)
                debversion = args.version.replace("-", "~") + ("" if args.channel == "stable" else "~" + args.channel) + "-" + args.build_number
                depends = {p["package"] + " (>= " + p["version"] + ")" for p in packages}
                control = f"Package: webhtv-pc\nVersion: {debversion}\nArchitecture: amd64\nMaintainer: WebHTV PC contributors\nSection: video\nPriority: optional\nDepends: {', '.join(sorted(depends))}\nRecommends: python3, openjdk-17-jre-headless\nDescription: WebHTV PC desktop media player\n"
                write_text(deb / "DEBIAN/control", control)
                command(["dpkg-deb", "--root-owner-group", "--build", deb, artifact])
            require_file(artifact)
            assets.append({"name": filename, "size": artifact.stat().st_size, "sha256": hash_file(artifact)})
        metadata["assets"] = assets
        write_json(work / "release-info.json", metadata)
        write_text(work / "SHA256SUMS.txt", "".join(a["sha256"] + "  " + a["name"] + "\n" for a in assets))
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".webhtv-publish-", dir=output) as publish:
            for name in filenames:
                shutil.copy2(work / name, Path(publish) / name)
            for name in filenames:
                os.replace(Path(publish) / name, output / name)
    print(f"Packaged {', '.join(a['name'] for a in assets)} in {output}")


def main(argv=None):
    try:
        build(parse_arguments(argv))
        return 0
    except (PackageError, OSError, ValueError, KeyError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f"Linux packaging failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
