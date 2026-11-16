"""Security and offline assembly tests; all fixtures stay in the allowed scratch root."""
import copy
import hashlib
import importlib.util
import io
import json
import pathlib
import stat
import struct
import tarfile
import tempfile
import unittest
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/prepare_python_runtime_linux.py'
SCRATCH = ROOT / '.local/python-runtime-linux'
SCRATCH.mkdir(parents=True, exist_ok=True)
if SCRIPT.exists():
    spec = importlib.util.spec_from_file_location('linux_runtime', SCRIPT)
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
else:
    runtime = None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def elf():
    data = bytearray(64)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<H', data, 18, 62)
    return bytes(data)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(runtime, 'Task 2 builder implementation is missing')
        self.temp = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.lock = json.loads((ROOT / 'scripts/python-runtime-linux.lock.json').read_text())
        self.lock.pop('assembled', None)
        self.files = {
            'bin/python3': elf(), 'lib/libpython3.14.so.1.0': elf(),
            'lib/python3.14/LICENSE.txt': b'CPython license',
            'lib/python3.14/os.py': b'# os',
            'lib/python3.14/encodings/__init__.py': b'# encodings',
        }
        site = 'lib/python3.14/site-packages/'
        for name in ('requests', 'Crypto', 'lxml', 'bs4'):
            self.files[site + name + '/__init__.py'] = b'# module'
        self.files[site + 'lxml/etree.cpython-314-x86_64-linux-gnu.so'] = elf()
        self.files[site + 'Crypto/Cipher/_raw_aes.abi3.so'] = elf()
        for p in self.lock['packages']:
            prefix = site + p['name'].replace('-', '_') + '-' + p['version'] + '.dist-info/'
            self.files[prefix + 'METADATA'] = ('Name: ' + p['name'] + '\nVersion: ' + p['version'] + '\n').encode()
            interpreter, abi, tags = p['filename'][:-4].split('-')[-3:]
            self.files[prefix + 'WHEEL'] = ('Wheel-Version: 1.0\n' + ''.join('Tag: ' + interpreter + '-' + abi + '-' + tag + '\n' for tag in tags.split('.'))).encode()
            self.files[prefix + 'RECORD'] = b'placeholder'
            self.files[prefix + 'licenses/LICENSE'] = b'package license'

    def bundle(self, files=None, infos=None):
        files = self.files if files is None else files
        out = self.root / 'bundle'
        out.mkdir(exist_ok=True)
        with zipfile.ZipFile(out / 'python-runtime.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                if infos and name in infos:
                    info = infos[name]
                z.writestr(info, data)
        arc = (out / 'python-runtime.zip').read_bytes()
        self.lock['assembled'] = dict(archiveSha256=digest(arc), size=len(arc),
                                     expandedSize=sum(map(len, files.values())), fileCount=len(files))
        manifest = dict(schemaVersion=1, platform='linux-x64', pythonVersion='3.14.10',
                        archive='python-runtime.zip', archiveSha256=digest(arc),
                        probeModules=['requests', 'Crypto', 'lxml', 'bs4'],
                        packages=[dict(name=p['name'], version=p['version']) for p in self.lock['packages']],
                        files=[dict(path=n, size=len(d), sha256=digest(d)) for n, d in sorted(files.items())])
        (out / 'bundle.json').write_text(json.dumps(manifest))
        return out

    def validate(self, out):
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime.subprocess, 'run', side_effect=AssertionError('validation executed code')), mock.patch.object(runtime.urllib.request, 'urlopen', side_effect=AssertionError('validation used network')):
            return runtime.validate_bundle(out)

    def test_pure_validation_returns_manifest(self):
        out = self.bundle()
        self.assertEqual(self.validate(out)['platform'], 'linux-x64')

    def test_manifest_types_platform_versions_and_hash_are_strict(self):
        for key, value in [('schemaVersion', True), ('platform', 'windows-x64'), ('pythonVersion', '3.14.9'), ('probeModules', ['Crypto', 'requests', 'lxml', 'bs4']), ('archiveSha256', '0' * 64), ('packages', [])]:
            with self.subTest(key=key):
                out = self.bundle()
                m = json.loads((out / 'bundle.json').read_text()); m[key] = value
                (out / 'bundle.json').write_text(json.dumps(m))
                with self.assertRaises(ValueError): self.validate(out)

    def test_tampered_archive_missing_output_and_extra_output_rejected(self):
        out = self.bundle()
        (out / 'python-runtime.zip').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): self.validate(out)
        out = self.bundle(); (out / 'bundle.json').unlink()
        with self.assertRaises(ValueError): self.validate(out)
        out = self.bundle(); (out / 'unexpected').write_bytes(b'')
        with self.assertRaises(ValueError): self.validate(out)

    def test_per_file_hash_crc_missing_file_and_license_rejected(self):
        out = self.bundle()
        m = json.loads((out / 'bundle.json').read_text()); m['files'][0]['sha256'] = '0' * 64
        (out / 'bundle.json').write_text(json.dumps(m))
        with self.assertRaises(ValueError): self.validate(out)
        for name in ('bin/python3', 'lib/python3.14/LICENSE.txt', 'lib/python3.14/site-packages/lxml/etree.cpython-314-x86_64-linux-gnu.so'):
            files = dict(self.files); del files[name]
            with self.assertRaises(ValueError): self.validate(self.bundle(files))
        out = self.bundle(); arc = bytearray((out / 'python-runtime.zip').read_bytes())
        at = arc.index(b'PK\x01\x02'); struct.pack_into('<I', arc, at + 16, 123)
        (out / 'python-runtime.zip').write_bytes(arc)
        self.lock['assembled']['archiveSha256'] = digest(arc)
        m = json.loads((out / 'bundle.json').read_text()); m['archiveSha256'] = digest(arc)
        (out / 'bundle.json').write_text(json.dumps(m))
        with self.assertRaises(ValueError): self.validate(out)

    def test_zip_unsafe_duplicate_and_file_directory_collision(self):
        for name in ('../escape', '/absolute', 'a/../b', 'a\\b', 'a:drive', 'CON', 'bad.', 'a//b'):
            with self.subTest(name=name):
                files = dict(self.files); files[name] = b'x'
                with self.assertRaises(ValueError): self.validate(self.bundle(files))
        for mode in (stat.S_IFLNK, stat.S_IFIFO, stat.S_IFCHR):
            info = zipfile.ZipInfo('bin/python3'); info.external_attr = (mode | 0o600) << 16
            with self.assertRaises(ValueError): self.validate(self.bundle(infos={'bin/python3': info}))
        for name in ('bin', 'BIN/python3'):
            files = dict(self.files); files[name] = b'x'
            with self.assertRaises(ValueError): self.validate(self.bundle(files))

    def test_size_and_count_caps(self):
        out = self.bundle()
        for name, cap in [('ZIP_CAP', 1), ('EXPANDED_CAP', 1), ('FILE_CAP', 1), ('MANIFEST_CAP', 1)]:
            with mock.patch.object(runtime, name, cap), self.assertRaises(ValueError): self.validate(out)

    def test_elf_arch_and_glibc_baseline(self):
        for content in (b'not an ELF', elf() + b'GLIBC_2.36\0'):
            files = dict(self.files); files['bin/python3'] = content
            with self.assertRaises(ValueError): self.validate(self.bundle(files))

    def tar(self, entries):
        path = self.root / 'source.tar.gz'
        with tarfile.open(path, 'w:gz') as t:
            for name, kind, target in entries:
                m = tarfile.TarInfo(name); m.type = kind
                if kind == tarfile.REGTYPE:
                    m.size = len(target); t.addfile(m, io.BytesIO(target))
                else:
                    m.linkname = target; t.addfile(m)
        return path

    def test_tar_flatten_verified_internal_link(self):
        source = self.tar([('python/bin/python3.14', tarfile.REGTYPE, b'verified'), ('python/bin/python3', tarfile.SYMTYPE, 'python3.14')])
        dest = self.root / 'tree'; dest.mkdir()
        runtime.extract_python(source, dest)
        self.assertEqual((dest / 'bin/python3').read_bytes(), b'verified')
        self.assertFalse((dest / 'bin/python3').is_symlink())

    def test_tar_absolute_escape_cycle_device_and_duplicate_rejected(self):
        cases = [
            [('python/../bad', tarfile.REGTYPE, b'x')],
            [('python/bin/python3', tarfile.SYMTYPE, '/etc/passwd')],
            [('python/bin/python3', tarfile.SYMTYPE, '../../outside')],
            [('python/bin/python3', tarfile.SYMTYPE, 'other'), ('python/bin/other', tarfile.SYMTYPE, 'python3')],
            [('python/device', tarfile.CHRTYPE, '')],
            [('python/file', tarfile.REGTYPE, b'x'), ('python/file', tarfile.REGTYPE, b'y')],
        ]
        for entries in cases:
            dest = self.root / ('tree' + str(len(list(self.root.iterdir())))); dest.mkdir()
            with self.assertRaises(ValueError): runtime.extract_python(self.tar(entries), dest)

    def test_download_cold_offline_reuse_and_bad_hash(self):
        data = b'locked source'
        a = dict(filename='fixture.tar.gz', url='https://example.invalid/fixture.tar.gz', size=len(data), sha256=digest(data))
        cache = self.root / 'cache'; cache.mkdir()
        with mock.patch.object(runtime.urllib.request, 'urlopen', return_value=io.BytesIO(data)) as fetch:
            p = runtime.get_artifact(a, cache, False)
            self.assertEqual(p.read_bytes(), data); self.assertEqual(fetch.call_count, 1)
        with mock.patch.object(runtime.urllib.request, 'urlopen', side_effect=AssertionError('offline network')):
            self.assertEqual(runtime.get_artifact(a, cache, True), p)
            p.write_bytes(b'bad')
            with self.assertRaises(ValueError): runtime.get_artifact(a, cache, True)
        p.unlink()
        with self.assertRaises(ValueError): runtime.get_artifact(a, cache, True)
        with mock.patch.object(runtime.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong source!')):
            with self.assertRaises(ValueError): runtime.get_artifact(a, cache, False)
        self.assertFalse(p.exists())

    def test_failure_preserves_valid_old_output_and_validate_only_no_rebuild(self):
        out = self.bundle(); before = {p.name: p.read_bytes() for p in out.iterdir()}
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', side_effect=ValueError('source hash mismatch')), mock.patch.object(runtime, 'invoke_probe', side_effect=AssertionError('unverified native execution')):
            with self.assertRaises(ValueError): runtime.build(out, self.root / 'cache', self.root / 'lock.json', True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in out.iterdir()})
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', side_effect=AssertionError('validate-only downloaded')):
            self.assertEqual(runtime.main(['--output-dir', str(out), '--validate-only']), 0)

    def test_local_crc_header_mismatch_rejected(self):
        out = self.bundle()
        arc = bytearray((out / 'python-runtime.zip').read_bytes())
        struct.pack_into('<I', arc, 14, 123)
        (out / 'python-runtime.zip').write_bytes(arc)
        self.lock['assembled']['archiveSha256'] = digest(arc)
        manifest = json.loads((out / 'bundle.json').read_text())
        manifest['archiveSha256'] = digest(arc)
        (out / 'bundle.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.validate(out)

    def test_malformed_lock_fails_as_value_error(self):
        self.bundle()
        for value in ([], 'wrong', None):
            lock = copy.deepcopy(self.lock)
            lock['python'] = value
            path = self.root / 'bad-lock.json'
            path.write_text(json.dumps(lock))
            with self.assertRaises(ValueError):
                runtime.read_lock(path)

    def test_invalid_locked_package_types_fail_as_value_error(self):
        self.bundle()
        for field, value in [('name', []), ('name', None), ('url', None), ('url', 123)]:
            with self.subTest(field=field, value=value):
                lock = copy.deepcopy(self.lock)
                lock['packages'][0][field] = value
                path = self.root / 'bad-package-lock.json'
                path.write_text(json.dumps(lock))
                with self.assertRaises(ValueError):
                    runtime.read_lock(path)

    def test_tar_hardlink_flattens_to_archive_file(self):
        source = self.tar([('python/bin/python3.14', tarfile.REGTYPE, b'verified'),
                           ('python/bin/python3', tarfile.LNKTYPE, 'python/bin/python3.14')])
        destination = self.root / 'tree'
        destination.mkdir()
        runtime.extract_python(source, destination)
        self.assertEqual((destination / 'bin/python3').read_bytes(), b'verified')
        self.assertFalse((destination / 'bin/python3').is_symlink())

    def test_unverified_tree_is_never_executed(self):
        out = self.bundle()
        tree = self.root / 'tree'
        tree.mkdir()
        for name, data in self.files.items():
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (tree / 'bin/python3').write_bytes(b'tampered')
        manifest = json.loads((out / 'bundle.json').read_text())
        with mock.patch.object(runtime.subprocess, 'run', side_effect=AssertionError('unverified code executed')):
            with self.assertRaises(ValueError):
                runtime.invoke_probe(tree, self.lock, manifest)

    def test_workspace_symlink_writes_rejected(self):
        link = self.root / 'link'; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError): runtime.workspace_directory(link / 'output')
        with self.assertRaises(ValueError): runtime.workspace_directory(pathlib.Path('/tmp/unscoped-output'))

    def publication_fixture(self):
        tree = self.root / 'publication-tree'
        tree.mkdir()
        for name, data in self.files.items():
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        output = self.root / 'published'
        output.mkdir()
        manifest = runtime.write_bundle(tree, output, self.lock)
        archive = output / 'python-runtime.zip'
        self.lock['assembled'] = dict(archiveSha256=manifest['archiveSha256'], size=archive.stat().st_size,
                                     expandedSize=sum(f['size'] for f in manifest['files']), fileCount=len(manifest['files']))
        return output, {path.name: path.read_bytes() for path in output.iterdir()}

    def publication_build(self, output):
        def extract(source, tree):
            for name, data in self.files.items():
                path = tree / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', return_value=self.root / 'unused-source'), mock.patch.object(runtime, 'extract_python', side_effect=extract), mock.patch.object(runtime, 'extract_wheel'), mock.patch.object(runtime, 'invoke_probe', return_value={'fixture': True}):
            return runtime.build(output, self.root / 'cache', self.root / 'lock.json', True)

    def test_copy_interruption_preserves_both_old_files(self):
        output, before = self.publication_fixture()
        for failure in (KeyboardInterrupt, OSError):
            with self.subTest(failure=failure.__name__):
                def interrupted_copy(source, destination, **kwargs):
                    destination = pathlib.Path(destination)
                    destination.mkdir()
                    (destination / 'bundle.json').write_bytes((pathlib.Path(source) / 'bundle.json').read_bytes())
                    raise failure('partial staging copy')
                with mock.patch.object(runtime.shutil, 'copytree', side_effect=interrupted_copy):
                    with self.assertRaises(failure):
                        self.publication_build(output)
                after = {path.name: path.read_bytes() for path in output.iterdir()} if output.exists() else {}
                self.assertEqual(after, before)
                self.validate(output)
                print('COPY_FAILURE_PRESERVED', failure.__name__, sorted(after))

    def test_rename_interruption_before_or_after_old_move_restores_old(self):
        output, before = self.publication_fixture()
        replace = runtime.os.replace
        for failure, after_move in ((KeyboardInterrupt, False), (KeyboardInterrupt, True), (OSError, False), (OSError, True)):
            with self.subTest(failure=failure.__name__, after_move=after_move):
                fired = False
                def interrupted_rename(source, destination):
                    nonlocal fired
                    if pathlib.Path(source) == output and not fired:
                        fired = True
                        if after_move:
                            replace(source, destination)
                        raise failure('old-output rename fault')
                    return replace(source, destination)
                with mock.patch.object(runtime.os, 'replace', side_effect=interrupted_rename):
                    with self.assertRaises(failure):
                        self.publication_build(output)
                after = {path.name: path.read_bytes() for path in output.iterdir()} if output.exists() else {}
                self.assertEqual(after, before)
                self.validate(output)
                print('OLD_RENAME_PRESERVED', failure.__name__, after_move, sorted(after))

    def test_final_rename_fault_restores_old_before_temporary_cleanup(self):
        output, before = self.publication_fixture()
        replace = runtime.os.replace
        for failure in (KeyboardInterrupt, OSError):
            with self.subTest(failure=failure.__name__):
                fired = False
                def failed_publish(source, destination):
                    nonlocal fired
                    if pathlib.Path(destination) == output and pathlib.Path(source).name == 'bundle' and not fired:
                        fired = True
                        raise failure('prepared-directory publish fault')
                    return replace(source, destination)
                with mock.patch.object(runtime.os, 'replace', side_effect=failed_publish):
                    with self.assertRaises(failure):
                        self.publication_build(output)
                self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
                self.validate(output)
                print('FINAL_RENAME_PRESERVED', failure.__name__, sorted(before))

    def test_failed_rollback_keeps_persistent_backup_and_next_build_recovers(self):
        output, before = self.publication_fixture()
        replace = runtime.os.replace
        def failed_publish_and_rollback(source, destination):
            if pathlib.Path(destination) == output:
                if pathlib.Path(source).name == 'previous':
                    raise OSError('rollback unavailable')
                raise KeyboardInterrupt('publish interrupted')
            return replace(source, destination)
        with mock.patch.object(runtime.os, 'replace', side_effect=failed_publish_and_rollback):
            with self.assertRaises(KeyboardInterrupt):
                self.publication_build(output)
        backups = [path for path in SCRATCH.glob('publish-*/previous') if path.is_dir()]
        matching = [path for path in backups if {item.name: item.read_bytes() for item in path.iterdir()} == before]
        self.assertEqual(len(matching), 1)
        backup = matching[0]
        self.assertTrue(backup.is_relative_to(SCRATCH))
        self.assertEqual(backup.stat().st_dev, output.parent.stat().st_dev)
        self.validate(backup)
        print('PERSISTENT_BACKUP', str(backup), sorted(before))
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', side_effect=ValueError('offline inputs unavailable')):
            with self.assertRaises(ValueError):
                runtime.build(output, self.root / 'cache', self.root / 'lock.json', True)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
        self.validate(output)
        self.assertFalse(backup.exists())
        print('RESTART_RECOVERED_BEFORE_INPUTS', sorted(before))

    def test_incomplete_staging_is_rejected_before_old_directory_moves(self):
        output, before = self.publication_fixture()
        def incomplete_copy(source, destination, **kwargs):
            destination = pathlib.Path(destination)
            destination.mkdir()
            (destination / 'bundle.json').write_bytes((pathlib.Path(source) / 'bundle.json').read_bytes())
            return destination
        with mock.patch.object(runtime.shutil, 'copytree', side_effect=incomplete_copy), mock.patch.object(runtime.os, 'replace', side_effect=AssertionError('old directory moved before staging validation')):
            with self.assertRaises(ValueError):
                self.publication_build(output)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)

    def test_publication_recovery_directory_symlink_cannot_escape_boundary(self):
        output, before = self.publication_fixture()
        transaction = SCRATCH / ('publish-' + digest(str(output).encode()))
        transaction.symlink_to(self.root, target_is_directory=True)
        try:
            with self.assertRaises(ValueError):
                self.publication_build(output)
            self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
        finally:
            transaction.unlink()

    def test_interruption_after_new_rename_preserves_valid_output_and_backup(self):
        output, before = self.publication_fixture()
        replace = runtime.os.replace
        def interrupt_after_publish(source, destination):
            result = replace(source, destination)
            if pathlib.Path(destination) == output and pathlib.Path(source).name == 'bundle':
                raise KeyboardInterrupt('published before interruption')
            return result
        with mock.patch.object(runtime.os, 'replace', side_effect=interrupt_after_publish):
            with self.assertRaises(KeyboardInterrupt):
                self.publication_build(output)
        transaction = SCRATCH / ('publish-' + digest(str(output).encode()))
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
        self.assertEqual({path.name: path.read_bytes() for path in (transaction / 'previous').iterdir()}, before)
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', side_effect=ValueError('offline inputs unavailable')):
            with self.assertRaises(ValueError):
                runtime.build(output, self.root / 'cache', self.root / 'lock.json', True)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
        self.assertFalse(transaction.exists())
        print('POST_RENAME_INTERRUPT_PRESERVED', sorted(before))

    def test_process_exit_leaves_persistent_backup_recovered_on_restart(self):
        output, before = self.publication_fixture()
        stage = self.root / 'subprocess-stage'
        runtime.shutil.copytree(output, stage)
        code = '''import sys,pathlib,json,os
sys.path.insert(0,sys.argv[1])
import prepare_python_runtime_linux as runtime
stage=pathlib.Path(sys.argv[2]); output=pathlib.Path(sys.argv[3]); lock=json.loads(sys.argv[4])
replace=runtime.os.replace
def exit_after_old_move(source,destination):
    result=replace(source,destination)
    if pathlib.Path(source)==output:
        os._exit(73)
    return result
runtime.os.replace=exit_after_old_move
runtime._publish_bundle(stage,output,lock)
'''
        result = runtime.subprocess.run([runtime.sys.executable, '-I', '-B', '-c', code,
                                         str(ROOT / 'scripts'), str(stage), str(output), json.dumps(self.lock)],
                                        env={'PATH': '', 'HOME': str(self.root)}, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 73, result.stderr)
        transaction = SCRATCH / ('publish-' + digest(str(output).encode()))
        backup = transaction / 'previous'
        self.assertFalse(output.exists())
        self.assertEqual({path.name: path.read_bytes() for path in backup.iterdir()}, before)
        self.assertTrue(backup.is_relative_to(SCRATCH))
        self.assertEqual(backup.stat().st_dev, output.parent.stat().st_dev)
        self.validate(backup)
        print('PROCESS_EXIT_BACKUP_PRESERVED', result.returncode, str(backup), sorted(before))
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'get_artifact', side_effect=ValueError('offline inputs unavailable')):
            with self.assertRaises(ValueError):
                runtime.build(output, self.root / 'cache', self.root / 'lock.json', True)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
        self.assertFalse(transaction.exists())
        print('PROCESS_EXIT_RESTART_RECOVERED', sorted(before))

    def test_real_cold_fixture_build_offline_determinism(self):
        source = self.tar([('python/' + n, tarfile.REGTYPE, d) for n, d in self.files.items() if 'site-packages' not in n] + [('python/bin/python3.14', tarfile.REGTYPE, elf())])
        self.lock['python'].update(filename=source.name, url='https://example.invalid/source', size=source.stat().st_size, sha256=digest(source.read_bytes()))
        artifacts = {source.name: source.read_bytes()}
        for p in self.lock['packages']:
            stem = p['name'].replace('-', '_') + '-' + p['version'] + '.dist-info/'
            b = io.BytesIO()
            with zipfile.ZipFile(b, 'w') as z:
                for n, d in self.files.items():
                    rel = n.removeprefix('lib/python3.14/site-packages/')
                    if rel.startswith(stem): z.writestr(rel, d)
                modules = {'requests': ['requests/'], 'pycryptodome': ['Crypto/'], 'lxml': ['lxml/'], 'beautifulsoup4': ['bs4/']}.get(p['name'], [])
                for n, d in self.files.items():
                    rel = n.removeprefix('lib/python3.14/site-packages/')
                    if any(rel.startswith(prefix) for prefix in modules): z.writestr(rel, d)
            data = b.getvalue(); p.update(size=len(data), sha256=digest(data)); artifacts[p['filename']] = data
        stage = self.root / 'seed'; stage.mkdir()
        tree = self.root / 'tree'; tree.mkdir()
        for n, d in self.files.items():
            p = tree / n; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(d)
        runtime.write_bundle(tree, stage, self.lock)
        archive = stage / 'python-runtime.zip'
        self.lock['assembled'] = dict(archiveSha256=digest(archive.read_bytes()), size=archive.stat().st_size, expandedSize=sum(map(len, self.files.values())), fileCount=len(self.files))
        cache = self.root / 'cache'; out = self.root / 'out'
        def fetch(request, **kwargs):
            url = request.full_url if hasattr(request, 'full_url') else request
            a = next(a for a in [self.lock['python']] + self.lock['packages'] if a['url'] == url)
            return io.BytesIO(artifacts[a['filename']])
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime.urllib.request, 'urlopen', side_effect=fetch), mock.patch.object(runtime, 'invoke_probe', return_value={'fixture': True}):
            runtime.build(out, cache, self.root / 'lock.json', False)
        before = {p.name: p.read_bytes() for p in out.iterdir()}
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime.urllib.request, 'urlopen', side_effect=AssertionError('offline network')), mock.patch.object(runtime, 'invoke_probe', return_value={'fixture': True}):
            runtime.build(out, cache, self.root / 'lock.json', True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in out.iterdir()})
        with mock.patch.object(runtime, 'read_lock', return_value=self.lock), mock.patch.object(runtime, 'invoke_probe', return_value={'fixture': True}), mock.patch.object(runtime.shutil, 'copytree', side_effect=OSError('simulated publication failure')):
            with self.assertRaises(OSError):
                runtime.build(out, cache, self.root / 'lock.json', True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in out.iterdir()})


if __name__ == '__main__':
    unittest.main()
