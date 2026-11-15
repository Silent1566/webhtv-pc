import ast
import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


CI = 'desktop-ci.yml'
RELEASE = 'desktop-release.yml'
LINUX_JOB = 'build-linux'


def workflow(name):
    path = ROOT / '.github/workflows' / name
    if not path.exists():
        raise AssertionError(f'Missing workflow: {path.name}')
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def steps(document, job=LINUX_JOB):
    if job not in document['jobs']:
        raise AssertionError(f'Missing job: {job}')
    return document['jobs'][job]['steps']


def step(document, name, job=LINUX_JOB):
    return next(item for item in steps(document, job) if item['name'] == name)


def python_body(script):
    return script.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]


class LinuxWorkflowTests(unittest.TestCase):
    def test_smoke_parsers_accept_actual_nested_build_flavor(self):
        info = ('WebHTV PC 0.1.0 (MVP-A (Windows)) platform=linux arch=x64 '
                'player=media-kit (libmpv) dart=3.13.4 (stable) on "linux_x64" startup=1939ms')
        ready = 'ready 2026-11-10T00:00:00\n' + info + '\ninteractive=1939ms\n'
        for filename in (CI, RELEASE):
            with self.subTest(filename=filename):
                script = python_body(step(workflow(filename), 'Smoke test both Linux packages', 'build-linux')['run'])
                tree = ast.parse(script)
                nodes = [node for node in tree.body
                         if (isinstance(node, ast.FunctionDef) and node.name == 'parse_ready')
                         or (isinstance(node, ast.Assign) and any(
                             isinstance(target, ast.Name) and target.id == 'info_pattern'
                             for target in node.targets))]
                namespace = {'re': re, 'version': '0.1.0'}
                exec(compile(ast.Module(body=nodes, type_ignores=[]), filename, 'exec'), namespace)
                try:
                    result = namespace['parse_ready'](ready)
                except RuntimeError as error:
                    self.fail(f'Actual nested build flavor was rejected: {error}')
                self.assertEqual(info, result)

    def test_ci_cannot_publish_and_release_is_manual_only(self):
        ci = workflow(CI)
        release = workflow(RELEASE)
        self.assertEqual({'push', 'pull_request', 'workflow_dispatch'}, set(ci['on']))
        self.assertEqual('read', ci['permissions']['contents'])
        self.assertEqual({'workflow_dispatch'}, set(release['on']))
        self.assertNotIn('gh release', str(ci))
        # 两个平台各自构建并烟测通过后，唯一的 publish job 才发布。
        publish_job = release['jobs']['publish']
        self.assertEqual(['meta', 'build-windows', 'build-linux'], publish_job['needs'])
        publish = step(release, 'Publish GitHub Release', 'publish')
        self.assertEqual('${{ inputs.publish_release }}', publish['if'])
        self.assertIn('release create', publish['run'])
        self.assertIn('Smoke test both Linux packages',
                      [item['name'] for item in steps(release, 'build-linux')])
        self.assertIn('Smoke test packaged client',
                      [item['name'] for item in steps(release, 'build-windows')])

    def test_both_workflows_obey_native_build_and_packager_contract(self):
        for filename in (CI, RELEASE):
            with self.subTest(filename=filename):
                document = workflow(filename)
                job = document['jobs'][LINUX_JOB]
                self.assertEqual('ubuntu-22.04', job['runs-on'])
                self.assertEqual('3.47.5', document['env']['FLUTTER_VERSION'])
                self.assertIn('npm ci --omit=dev', str(document))
                self.assertNotIn('build.ps1', str(document))
                self.assertIn('flutter build linux --release', str(document))
                self.assertIn('dart analyze', str(document))
                self.assertIn('xvfb-run -a flutter test', str(document))
                run = step(document, 'Package AppImage and deb')['run']
                for flag in ('--build-dir', '--output-dir', '--version', '--build-number',
                             '--channel', '--commit', '--short-commit', '--built-at',
                             '--flutter-version', '--node-version', '--appimagetool'):
                    self.assertIn(flag + ' ', run)
                self.assertIn('dist/linux', run)
                self.assertNotIn('--formats', run)
                tool = step(document, 'Install verified appimagetool')['run']
                self.assertIn('/1.9.1/appimagetool-x86_64.AppImage', tool)
                self.assertIn('ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0', tool)
                self.assertLess(tool.index('sha256sum --check'), tool.index('chmod +x'))
                for item in steps(document):
                    if 'run' in item:
                        self.assertNotRegex(item['run'], r'\$\{\{.*\}\}')

    def test_embedded_shell_and_python_have_valid_syntax(self):
        for filename in (CI, RELEASE):
            for item in steps(workflow(filename)):
                if 'run' not in item:
                    continue
                result = subprocess.run(['bash', '-n'], input=item['run'], text=True,
                                        capture_output=True)
                self.assertEqual(0, result.returncode, f"{filename}:{item['name']}: {result.stderr}")
                if "python3 - <<'PY'" in item['run']:
                    compile(python_body(item['run']), item['name'], 'exec')

    def test_release_metadata_uses_commit_time_and_rejects_tag_mismatch(self):
        code = python_body(step(workflow(RELEASE), 'Resolve release metadata', 'meta')['run'])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'apps/desktop-flutter').mkdir(parents=True)
            (root / 'apps/desktop-flutter/pubspec.yaml').write_text('version: 1.2.3+9\n')
            env = dict(os.environ, GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.org',
                       GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.org',
                       GIT_AUTHOR_DATE='2026-12-03T00:00:00Z',
                       GIT_COMMITTER_DATE='2026-12-03T00:00:00Z',
                       GITHUB_REF_NAME='main', RELEASE_CHANNEL_INPUT='auto',
                       RELEASE_TAG_INPUT='', GITHUB_OUTPUT=str(root / 'output'))
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, env=env, text=True).strip()
            git('init', '-q')
            git('add', '.')
            git('commit', '-qm', 'fixture')
            env['GITHUB_SHA'] = git('rev-parse', 'HEAD')
            def resolve():
                (root / 'output').write_text('')
                return subprocess.run(['python3', '-c', code], cwd=root, env=env,
                                      capture_output=True, text=True)
            result = resolve()
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn('tag=v1.2.3-202612030800\n', (root / 'output').read_text())
            env['GITHUB_REF_NAME'] = 'dev3'
            self.assertEqual(0, resolve().returncode)
            self.assertIn('tag=v1.2.3-beta-202612030800\n', (root / 'output').read_text())
            env['RELEASE_TAG_INPUT'] = 'v1.2.3-beta-202612030800'
            git('tag', '-a', env['RELEASE_TAG_INPUT'], '-m', 'annotated')
            self.assertEqual(0, resolve().returncode)
            git('commit', '--allow-empty', '-qm', 'other commit')
            env['GITHUB_SHA'] = git('rev-parse', 'HEAD')
            result = resolve()
            self.assertNotEqual(0, result.returncode)
            self.assertIn('will not move', result.stderr)
            env['RELEASE_TAG_INPUT'] = 'v1.2.3-beta-202612030800\nINJECT=value'
            self.assertNotEqual(0, resolve().returncode)

    def test_merged_publish_merges_both_platforms_into_one_release(self):
        merge = step(workflow(RELEASE), 'Merge desktop assets and checksums', 'publish')['run']
        publish = step(workflow(RELEASE), 'Publish GitHub Release', 'publish')['run']
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            windows = root / 'artifacts/windows'
            linux = root / 'artifacts/linux'
            windows.mkdir(parents=True)
            linux.mkdir(parents=True)
            (windows / 'webhtv-pc-1.2.3-beta-windows-x64.zip').write_text('zip')
            (linux / 'webhtv-pc-1.2.3-beta-linux-x64.AppImage').write_text('appimage')
            (linux / 'webhtv-pc-1.2.3-beta-linux-x64.deb').write_text('deb')
            (windows / 'release-info.json').write_text('windows-metadata')
            (linux / 'release-info.json').write_text('linux-metadata')

            def checksums(directory):
                entries = []
                for name in sorted(p.name for p in directory.iterdir()
                                   if p.name not in ('SHA256SUMS.txt', 'release-info.json')):
                    digest = hashlib.sha256((directory / name).read_bytes()).hexdigest()
                    entries.append(digest + '  ' + name)
                return chr(10).join(entries) + chr(10)

            (windows / 'SHA256SUMS.txt').write_text(checksums(windows))
            (linux / 'SHA256SUMS.txt').write_text(checksums(linux))
            result = subprocess.run(['bash', '-e', '-u', '-o', 'pipefail', '-c', merge], cwd=root,
                                    capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            dist = root / 'dist'
            self.assertEqual({'webhtv-pc-1.2.3-beta-windows-x64.zip',
                              'webhtv-pc-1.2.3-beta-linux-x64.AppImage',
                              'webhtv-pc-1.2.3-beta-linux-x64.deb',
                              'release-info.json', 'linux-release-info.json',
                              'SHA256SUMS.txt'}, {p.name for p in dist.iterdir()})
            # Windows 保留原名，Linux 改名成 linux-release-info.json，互不覆盖。
            self.assertEqual('windows-metadata', (dist / 'release-info.json').read_text())
            self.assertEqual('linux-metadata', (dist / 'linux-release-info.json').read_text())
            merged = (dist / 'SHA256SUMS.txt').read_text()
            self.assertIn('webhtv-pc-1.2.3-beta-windows-x64.zip', merged)
            self.assertIn('webhtv-pc-1.2.3-beta-linux-x64.AppImage', merged)
            self.assertEqual(3, len(merged.strip().splitlines()))

            (root / 'build').mkdir()
            (root / 'build/release-notes.md').write_text('notes')
            (root / 'bin').mkdir()
            gh = root / 'bin/gh'
            gh.write_text("#!/bin/bash\nprintf \"%s\n\" \"$*\" >> \"$GH_LOG\"\nif [ \"$1 $2\" = \"release view\" ]; then exit 0; fi\n")
            gh.chmod(0o755)
            base_path = os.environ.get('PATH') or '/usr/local/bin:/usr/bin:/bin'
            env = dict(os.environ, PATH=str(root / 'bin') + ':' + base_path,
                       GH_LOG=str(root / 'gh.log'), GITHUB_SHA='f' * 40,
                       RELEASE_TAG='v1.2.3-beta-202612030800',
                       RELEASE_TITLE='1.2.3-beta-202612030800',
                       RELEASE_PRERELEASE='true', NOTES_FILE='build/release-notes.md')
            subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
            result = subprocess.run(['bash', '-e', '-u', '-o', 'pipefail', '-c', publish], cwd=root,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            calls = (root / 'gh.log').read_text()
            self.assertIn('release view', calls)
            self.assertIn('release upload', calls)
            self.assertIn('--clobber', calls)
            self.assertIn('linux-release-info.json', calls)
            self.assertIn('release edit', calls)
            self.assertNotIn('release create', calls)

    def test_smoke_requires_ready_protocol_mapped_window_and_survival(self):
        for filename in (CI, RELEASE):
            code = step(workflow(filename), 'Smoke test both Linux packages', 'build-linux')['run']
            self.assertIn("['dpkg-deb', '--extract'", code)
            self.assertIn('APPIMAGE_EXTRACT_AND_RUN', code)
            self.assertIn('--screenshot-ready-file=', code)
            self.assertIn('--startup-trace=', code)
            # Readiness marker must be the documented three-line protocol, not one blob.
            self.assertIn("lines[0].startswith('ready ')", code)
            self.assertIn('startup-info-unavailable', code)
            self.assertIn('arch != ', code)
            self.assertIn('media-kit', code)
            # A mapped window owned by the process tree, not just a written marker.
            self.assertIn("'xwininfo', '-root', '-children'", code)
            self.assertIn('_NET_WM_PID', code)
            self.assertIn('Map State: IsViewable', code)
            self.assertIn('process_tree_pids', code)
            # Bounded post-readiness survival, plus the earlier crash guards.
            self.assertIn('exited within 3s after readiness', code)
            self.assertIn('exited after writing the ready marker', code)
            self.assertIn('exited before readiness', code)
            self.assertIn('runtime/node/node', code)
            self.assertIn('sidecars/spider-host-jvm/host.jar', code)
            self.assertIn('os.killpg', code)

    def test_notes_treat_untrusted_input_as_data_and_force_beta_prerelease(self):
        code = python_body(step(workflow(RELEASE), 'Prepare Linux release notes')['run'])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = dict(os.environ, APP_VERSION='1.2.3', APP_CHANNEL='beta',
                       PRERELEASE_INPUT='false', RELEASE_NOTES_INPUT='$(touch injected)\\nsecond line',
                       GITHUB_OUTPUT=str(root / 'output'))
            result = subprocess.run(['python3', '-c', code], cwd=root, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse((root / 'injected').exists())
            self.assertIn('$(touch injected)\nsecond line',
                          (root / 'build/linux-release-notes.md').read_text())
            self.assertEqual('is_prerelease=true\n', (root / 'output').read_text())

    def test_smoke_protocol_window_and_crash_regressions(self):
        """Real X11 windows, fake client/AppImage, real deb extraction; no Flutter claims."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / 'package'
            app = package / 'opt/webhtv-pc'
            for directory in ('lib', 'data', 'runtime/node', 'sidecars/spider-host-python',
                              'sidecars/spider-host-js', 'sidecars/spider-host-jvm'):
                (app / directory).mkdir(parents=True, exist_ok=True)
            for relative in ('sidecars/spider-host-python/host.py', 'sidecars/spider-host-js/host.js',
                             'sidecars/spider-host-jvm/host.jar'):
                (app / relative).write_text('fixture')
            node = app / 'runtime/node/node'
            node.write_text('#!/bin/sh\necho fixture-node\n')
            node.chmod(0o755)
            client = app / 'webhtv_pc'
            client.write_text(r'''#!/usr/bin/env python3
import ctypes as C
import datetime
import os
import subprocess
import sys
import time
from pathlib import Path

if '--fixture-window' in sys.argv:
    x = C.CDLL('libX11.so.6')
    D, W = C.c_void_p, C.c_ulong
    signatures = {
        'XOpenDisplay': (D, [C.c_char_p]),
        'XDefaultRootWindow': (W, [D]),
        'XCreateSimpleWindow': (W, [D, W, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_uint, W, W]),
        'XInternAtom': (W, [D, C.c_char_p, C.c_int]),
        'XChangeProperty': (C.c_int, [D, W, W, W, C.c_int, C.c_int, C.POINTER(C.c_ubyte), C.c_int]),
        'XMapWindow': (C.c_int, [D, W]),
        'XSync': (C.c_int, [D, C.c_int]),
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(x, name)
        function.restype, function.argtypes = result, arguments
    display = x.XOpenDisplay(None)
    if not display:
        raise SystemExit('fixture X11 display unavailable')
    window = x.XCreateSimpleWindow(display, x.XDefaultRootWindow(display), 5, 5, 320, 180, 0, 0, 0)
    pid = C.c_ulong(os.getpid())
    x.XChangeProperty(display, window, x.XInternAtom(display, b'_NET_WM_PID', 0),
                      x.XInternAtom(display, b'CARDINAL', 0), 32, 0,
                      C.cast(C.byref(pid), C.POINTER(C.c_ubyte)), 1)
    x.XMapWindow(display, window)
    x.XSync(display, 0)
    time.sleep(120)
    raise SystemExit()

mode = os.environ['FIXTURE_MODE']
# Optionally target AppImage while keeping the first (deb) smoke healthy.
if os.environ.get('FIXTURE_ONLY_IMAGE') == '1' and Path(sys.argv[0]).parent.name.startswith('client with spaces'):
    mode = 'valid'
if mode not in ('no-window', 'marker-only', 'exit'):
    subprocess.Popen([sys.executable, __file__, '--fixture-window'])
ready = Path(next(a.split('=', 1)[1] for a in sys.argv if a.startswith('--screenshot-ready-file=')))
version = '9.9.9' if mode == 'wrong-version' else '1.2.3'
platform = 'windows' if mode == 'wrong-platform' else 'linux'
arch = 'arm64' if mode == 'wrong-arch' else 'x64'
player = 'other' if mode == 'wrong-player' else 'media-kit'
info = f'WebHTV PC {version} (dev) platform={platform} arch={arch} player={player} dart=fixture startup=10ms'
if mode == 'missing-info':
    info = 'startup-info-unavailable'
body = f'ready {datetime.datetime.now().isoformat()}\n{info}\nfirst-frame=5ms interactive=10ms\n'
if mode == 'marker-only':
    body = info
ready.write_text(body)
if mode == 'exit':
    sys.exit(1)
if mode == 'delayed-exit':
    time.sleep(1)
    sys.exit(1)
time.sleep(120)
''')
            client.chmod(0o755)
            (package / 'DEBIAN').mkdir()
            (package / 'DEBIAN/control').write_text('Package: fixture\nVersion: 1.2.3\nArchitecture: amd64\nMaintainer: Test <test@example.org>\nDescription: test fixture\n')
            (root / 'dist/linux').mkdir(parents=True)
            deb = root / 'dist/linux/webhtv-pc-1.2.3-dev-linux-x64.deb'
            subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(package), str(deb)],
                           check=True, stdout=subprocess.DEVNULL)
            image = root / 'dist/linux/webhtv-pc-1.2.3-dev-linux-x64.AppImage'
            image.write_text("#!/usr/bin/env python3\nimport os,sys,shutil\nfrom pathlib import Path\n"
                             "app=Path(os.environ['FIXTURE_APPDIR'])\n"
                             "if '--appimage-extract' in sys.argv:\n shutil.copytree(app,'squashfs-root')\n"
                             "else:\n os.execv(str(app/'webhtv_pc'),[str(app/'webhtv_pc'),*sys.argv[1:]])\n")
            image.chmod(0o755)
            cases = [('valid', True, None), ('wrong-version', False, 'unexpected startup info'),
                     ('wrong-platform', False, 'unexpected startup info'),
                     ('wrong-arch', False, 'unexpected startup info'),
                     ('wrong-player', False, 'unexpected startup info'),
                     ('missing-info', False, 'unexpected startup info'),
                     ('marker-only', False, 'invalid ready protocol'),
                     ('exit', False, 'exited'), ('delayed-exit', False, 'exited'),
                     ('no-window', False, 'no mapped X11 window')]
            for filename in (CI, RELEASE):
                code = python_body(step(workflow(filename), 'Smoke test both Linux packages', 'build-linux')['run'])
                for mode, succeeds, error in cases:
                    with self.subTest(workflow=filename, mode=mode):
                        smoke = root / (filename + '-' + mode)
                        smoke.mkdir()
                        env = dict(os.environ, APP_VERSION='1.2.3', APP_CHANNEL='dev',
                                   FIXTURE_APPDIR=str(app), FIXTURE_MODE=mode, SMOKE_DIR=str(smoke),
                                   APPIMAGE_EXTRACT_AND_RUN='1', FIXTURE_ONLY_IMAGE='1' if mode == 'delayed-exit' else '0')
                        result = subprocess.run(['xvfb-run', '-a', 'python3', '-c', code],
                                                cwd=root, env=env, capture_output=True,
                                                text=True, timeout=30)
                        self.assertEqual(succeeds, result.returncode == 0, result.stdout[-2000:] + result.stderr)
                        if succeeds:
                            self.assertIn('appimage ready:', result.stdout)
                            self.assertIn('deb ready:', result.stdout)
                            self.assertIn('mapped X11 window', result.stdout)
                        else:
                            self.assertIn(error, result.stderr)

    def test_player_dependency_is_version_agnostic(self):
        for filename in (CI, RELEASE):
            text = (ROOT / '.github/workflows' / filename).read_text()
            self.assertNotIn('libmpv.so.', text)
            self.assertNotIn('libmpv2', text)
            self.assertIn('libmpv-dev', text)
        # A documented baseline soname is not an installation dependency assumption.
        doc = (ROOT / 'docs/linux-packaging.md').read_text()
        self.assertIn('libmpv.so.1', doc)
        self.assertIn('libmpv-dev', doc)
        self.assertIn('ldconfig', doc)


if __name__ == '__main__':
    unittest.main()
