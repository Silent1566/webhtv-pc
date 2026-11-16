#!/usr/bin/env python3
"""Build and validate the hash-locked, relocatable Linux x86_64 Python bundle."""
import argparse
import email.parser
import hashlib
import json
import os
import pathlib
import platform
import posixpath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_LOCK = pathlib.Path(__file__).resolve().with_name('python-runtime-linux.lock.json')
ZIP_CAP = 64 * 1024 * 1024
EXPANDED_CAP = 128 * 1024 * 1024
FILE_CAP = 10000
MANIFEST_CAP = 4 * 1024 * 1024
PYTHON_VERSION = '3.14.10'
PYTHON_FILENAME = 'cpython-3.14.10+20261110-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz'
RELEASE_URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20261110/'
PYTHON_SHA256 = 'c2ff2e97422f5d3896a16e0317fd212ba977bbf2688d93a6f7a03d817506bd30'
VERSIONS = {
    'requests': '2.34.2', 'urllib3': '2.8.0', 'charset-normalizer': '3.5.2',
    'idna': '3.20', 'certifi': '2026.10.23', 'pycryptodome': '3.24.1',
    'lxml': '6.1.3', 'beautifulsoup4': '4.15.0', 'soupsieve': '4.1',
    'typing-extensions': '4.16.0',
}
SITE = 'lib/python3.14/site-packages/'
PROBES = ['requests', 'Crypto', 'lxml', 'bs4']


def safe_relative(name):
    if not isinstance(name, str) or not name or name.startswith('/') or '\\' in name or ':' in name:
        raise ValueError('Unsafe relative path: ' + repr(name))
    for part in name.split('/'):
        if (part in ('', '.', '..') or part.endswith(('.', ' '))
                or re.search(r'[<>"|?*\x00-\x1f]', part)
                or re.match(r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)', part, re.I)):
            raise ValueError('Unsafe relative path: ' + name)
    return name


def no_links(path):
    path = pathlib.Path(os.path.abspath(path))
    for current in (path, *path.parents):
        if current.is_symlink():
            raise ValueError('Symlink path/ancestor: ' + str(current))
    return path


def workspace_directory(path):
    path = no_links(path)
    scratch = ROOT / '.local/python-runtime-linux'
    if path != ROOT / 'runtime/python' and path != scratch and not path.is_relative_to(scratch):
        raise ValueError('Output/cache outside runtime/python or .local/python-runtime-linux: ' + str(path))
    if path.exists() and not path.is_dir():
        raise ValueError('Expected directory: ' + str(path))
    return path


def sha256_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def is_hash(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def json_object(path, cap=None):
    cap = MANIFEST_CAP if cap is None else cap
    path = no_links(path)
    if not path.is_file() or not integer(path.stat().st_size, 1, cap):
        raise ValueError('Missing or oversized JSON: ' + str(path))
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    try:
        result = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError('Invalid JSON: ' + str(path)) from exc
    if not isinstance(result, dict):
        raise ValueError('JSON must be an object')
    return result


def wheel_tags(filename):
    parts = filename[:-4].split('-')
    if len(parts) != 5 or not filename.endswith('.whl'):
        raise ValueError('Invalid wheel filename: ' + filename)
    interpreter, abi, platforms = parts[-3:]
    if interpreter in ('py3', 'py2.py3') and abi == 'none' and platforms == 'any':
        pass
    elif (interpreter == 'cp314' and abi == 'cp314') or (re.fullmatch(r'cp3[7-9]', interpreter) and abi == 'abi3'):
        for tag in platforms.split('.'):
            match = re.fullmatch(r'manylinux_2_(\d+)_x86_64', tag)
            if tag not in ('manylinux1_x86_64', 'manylinux2010_x86_64', 'manylinux2014_x86_64') and (not match or int(match[1]) > 35):
                raise ValueError('Wheel incompatible with glibc 2.35: ' + filename)
    else:
        raise ValueError('Wheel incompatible with CPython 3.14: ' + filename)
    return {f'{i}-{abi}-{p}' for i in interpreter.split('.') for p in platforms.split('.')}


def read_lock(path):
    lock = json_object(path)
    if type(lock.get('schemaVersion')) is not int or lock['schemaVersion'] != 1 or lock.get('platform') != 'linux-x64':
        raise ValueError('Invalid Linux lock schema/platform')
    python = lock.get('python', {})
    if not isinstance(python, dict):
        raise ValueError('Invalid Python lock object')
    if (python.get('version') != PYTHON_VERSION or python.get('filename') != PYTHON_FILENAME
            or python.get('url') != RELEASE_URL + PYTHON_FILENAME.replace('+', '%2B')
            or python.get('sha256') != PYTHON_SHA256 or python.get('size') != 36875876
            or python.get('evidenceUrl') != RELEASE_URL + 'SHA256SUMS'):
        raise ValueError('Invalid pinned standalone CPython artifact')
    packages = lock.get('packages')
    if not isinstance(packages, list) or len(packages) != len(VERSIONS):
        raise ValueError('Incomplete locked wheel closure')
    seen = set()
    for p in packages:
        if (not isinstance(p, dict) or not isinstance(p.get('name'), str)
                or p['name'] in seen or VERSIONS.get(p['name']) != p.get('version')):
            raise ValueError('Wrong or duplicate locked package version')
        seen.add(p['name'])
        filename = p.get('filename')
        safe_relative(filename)
        if '/' in filename or not filename.startswith(p['name'].replace('-', '_') + '-' + p['version'] + '-'):
            raise ValueError('Wrong locked wheel filename')
        wheel_tags(filename)
        if (not isinstance(p.get('url'), str)
                or not p['url'].startswith('https://files.pythonhosted.org/packages/')
                or p['url'].rsplit('/', 1)[-1] != filename
                or p.get('evidenceUrl') != f"https://pypi.org/pypi/{p['name']}/{p['version']}/json"):
            raise ValueError('Wrong locked wheel source URL')
    for a in [python] + packages:
        if not is_hash(a.get('sha256')) or not integer(a.get('size'), 1, ZIP_CAP):
            raise ValueError('Invalid locked source size/hash')
    assembly = lock.get('assembled')
    if (not isinstance(assembly, dict) or set(assembly) != {'archiveSha256', 'size', 'expandedSize', 'fileCount'}
            or not is_hash(assembly.get('archiveSha256')) or not integer(assembly.get('size'), 1, ZIP_CAP)
            or not integer(assembly.get('expandedSize'), 1, EXPANDED_CAP)
            or not integer(assembly.get('fileCount'), 1, FILE_CAP)):
        raise ValueError('Missing/invalid trusted assembly digest and limits')
    return lock


def get_artifact(artifact, cache, offline):
    cache = workspace_directory(cache)
    cache.mkdir(parents=True, exist_ok=True)
    name = safe_relative(artifact['filename'])
    if '/' in name:
        raise ValueError('Artifact filename must be a basename')
    path = no_links(cache / name)
    def verify(candidate):
        if not candidate.is_file() or candidate.stat().st_size != artifact['size'] or sha256_file(candidate) != artifact['sha256']:
            raise ValueError('Source SHA256/size mismatch: ' + str(candidate))
    if path.exists():
        verify(path)
        return path
    if offline:
        raise ValueError('Offline cache miss: ' + name)
    with tempfile.NamedTemporaryFile(dir=cache, prefix=name + '.', suffix='.part', delete=False) as stream:
        partial = pathlib.Path(stream.name)
        try:
            with urllib.request.urlopen(artifact['url'], timeout=120) as response:
                total = 0
                while True:
                    data = response.read(min(65536, artifact['size'] + 1 - total))
                    if not data:
                        break
                    total += len(data)
                    if total > artifact['size'] or total > ZIP_CAP:
                        raise ValueError('Download exceeds locked size')
                    stream.write(data)
            stream.flush()
            verify(partial)
            if path.exists() or no_links(partial).parent != cache:
                raise ValueError('Unsafe cache publication target')
            os.replace(partial, path)
        except Exception:
            no_links(partial)
            partial.unlink(missing_ok=True)
            raise
    return path


def check_paths(names):
    seen = set()
    for name in names:
        safe_relative(name)
        key = name.lower()
        if key in seen or key in ('.bundle.json', 'bundle.json') or any(p in ('__pycache__', 'spiders', 'manifests', '.git') for p in key.split('/')):
            raise ValueError('Duplicate or reserved file path: ' + name)
        seen.add(key)
    for key in seen:
        parent = posixpath.dirname(key)
        while parent:
            if parent in seen:
                raise ValueError('File/directory collision: ' + key)
            parent = posixpath.dirname(parent)


def write_file(tree, name, stream, size):
    safe_relative(name)
    target = no_links(tree / name)
    if target.exists():
        raise ValueError('Extraction would overwrite: ' + name)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open('xb') as output:
        written = 0
        while True:
            data = stream.read(min(65536, size + 1 - written))
            if not data:
                break
            written += len(data)
            if written > size:
                raise ValueError('Expanded file exceeds declared size: ' + name)
            output.write(data)
        if written != size:
            raise ValueError('Expanded file size mismatch: ' + name)
    target.chmod(0o600)


def keep_python(name):
    license_file = any(word in name.lower() for word in ('license', 'licence', 'copying', 'notice', 'authors'))
    if license_file:
        return True
    if name == 'bin/python3':
        return True
    if not name.startswith('lib/') or name in ('lib/libpython3.14.so',):
        return False
    if name.startswith(('lib/pkgconfig/', SITE, 'lib/python3.14/config-')):
        return False
    if name.endswith(('.pyc', '.pyo', '.a', '.h')) or any(part in ('test', 'tests', '__pycache__') for part in name.split('/')):
        return False
    return True


def extract_python(archive, tree):
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        if len(members) > FILE_CAP or sum(m.size for m in members) > EXPANDED_CAP:
            raise ValueError('Standalone source exceeds expansion limits')
        table = {}
        for m in members:
            name = m.name.rstrip('/') if m.isdir() else m.name
            safe_relative(name)
            if not name.startswith('python/') or name in table or not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise ValueError('Unsafe/duplicate standalone member: ' + name)
            if not integer(m.size, 0, EXPANDED_CAP):
                raise ValueError('Invalid tar member size')
            table[name] = m
        resolved = {}
        for name in table:
            current = name
            chain = set()
            while table[current].issym() or table[current].islnk():
                if current in chain:
                    raise ValueError('Cyclic tar link: ' + name)
                chain.add(current)
                m = table[current]
                target = m.linkname
                if not target or target.startswith('/') or '\\' in target or ':' in target:
                    raise ValueError('Absolute/unsafe tar link: ' + name)
                target = posixpath.normpath(posixpath.join(posixpath.dirname(current), target) if m.issym() else target)
                safe_relative(target)
                if not target.startswith('python/') or target not in table:
                    raise ValueError('Out-of-archive tar link: ' + name)
                current = target
            if table[name].issym() or table[name].islnk():
                if not table[current].isfile():
                    raise ValueError('Link target is not an archive regular file')
            resolved[name] = table[current]
        selected = [(name[7:], resolved[name]) for name, m in table.items() if not m.isdir() and keep_python(name[7:])]
        check_paths(n for n, _ in selected)
        if len(selected) > FILE_CAP or sum(m.size for _, m in selected) > EXPANDED_CAP:
            raise ValueError('Flattened standalone exceeds expansion limits')
        for name, m in sorted(selected):
            with tar.extractfile(m) as source:
                write_file(tree, name, source, m.size)


def zip_entries(archive):
    entries = archive.infolist()
    if not entries or len(entries) > FILE_CAP or sum(e.file_size for e in entries) > EXPANDED_CAP:
        raise ValueError('ZIP exceeds file/expanded size limits')
    regular = []
    seen = set()
    for e in entries:
        name = e.filename.rstrip('/') if e.is_dir() else e.filename
        safe_relative(name)
        if name.lower() in seen:
            raise ValueError('Duplicate ZIP path: ' + name)
        seen.add(name.lower())
        kind = stat.S_IFMT(e.external_attr >> 16)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR) or (e.external_attr & 0x400) or (e.flag_bits & 1) or e.compress_type not in (0, 8):
            raise ValueError('ZIP link/special/encrypted/unsupported member')
        if e.is_dir():
            if kind not in (0, stat.S_IFDIR) or e.file_size:
                raise ValueError('Invalid ZIP directory')
        else:
            if kind == stat.S_IFDIR or not integer(e.file_size, 0, EXPANDED_CAP):
                raise ValueError('Invalid ZIP file')
            regular.append(e)
    check_paths(e.filename for e in regular)
    return regular


def extract_wheel(archive, tree, package):
    with zipfile.ZipFile(archive) as wheel:
        entries = zip_entries(wheel)
        for e in entries:
            if '.data/' in e.filename:
                raise ValueError('Unsupported wheel relocation scheme')
        if sum(p.stat().st_size for p in tree.rglob('*') if p.is_file()) + sum(e.file_size for e in entries) > EXPANDED_CAP:
            raise ValueError('Installed wheels exceed expanded cap')
        for e in entries:
            with wheel.open(e) as source:
                write_file(tree, SITE + e.filename, source, e.file_size)


def check_elf(data, name):
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 62:
        raise ValueError('Not a Linux x86_64 ELF: ' + name)
    for version in re.findall(rb'GLIBC_(\d+)\.(\d+)(?:\.(\d+))?\x00', data):
        if tuple(int(v or b'0') for v in version) > (2, 35, 0):
            raise ValueError('ELF requires glibc newer than 2.35: ' + name)


def required_files(files, lock):
    required = ['bin/python3', 'lib/libpython3.14.so.1.0', 'lib/python3.14/LICENSE.txt',
                'lib/python3.14/encodings/__init__.py', 'lib/python3.14/os.py']
    required += [SITE + m + '/__init__.py' for m in ('requests', 'Crypto', 'lxml', 'bs4')]
    for name in required:
        if name not in files or not files[name]['size']:
            raise ValueError('Bundle missing required implementation/license: ' + name)
    for prefix in (SITE + 'lxml/etree.', SITE + 'Crypto/Cipher/_raw_aes.'):
        if not any(n.startswith(prefix) and n.endswith('.so') and files[n]['size'] for n in files):
            raise ValueError('Bundle missing native extension: ' + prefix)
    for p in lock['packages']:
        prefix = SITE + p['name'].replace('-', '_') + '-' + p['version'] + '.dist-info/'
        for suffix in ('METADATA', 'WHEEL', 'RECORD'):
            if prefix + suffix not in files or not files[prefix + suffix]['size']:
                raise ValueError('Missing package dist-info: ' + prefix + suffix)
        if not any(n.startswith(prefix) and any(s in n.lower() for s in ('license', 'licence', 'copying')) and files[n]['size'] for n in files):
            raise ValueError('Missing dependency license: ' + p['name'])


def _validate_bundle(directory, lock):
    try:
        directory = no_links(directory)
        if not directory.is_dir() or {p.name for p in directory.iterdir()} != {'bundle.json', 'python-runtime.zip'}:
            raise ValueError('Bundle must contain exactly bundle.json and python-runtime.zip')
        for p in directory.iterdir():
            if not stat.S_ISREG(no_links(p).stat().st_mode):
                raise ValueError('Bundle contains non-regular files')
        manifest = json_object(directory / 'bundle.json')
        if set(manifest) != {'schemaVersion', 'platform', 'pythonVersion', 'archive', 'archiveSha256', 'probeModules', 'packages', 'files'}:
            raise ValueError('Invalid manifest fields')
        if (type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1
                or manifest['platform'] != 'linux-x64' or manifest['pythonVersion'] != PYTHON_VERSION
                or manifest['archive'] != 'python-runtime.zip' or not is_hash(manifest['archiveSha256'])
                or manifest['probeModules'] != PROBES):
            raise ValueError('Invalid manifest schema/platform/version/probe/hash')
        packages = manifest['packages']
        if (not isinstance(packages, list) or len(packages) != len(VERSIONS)
                or any(not isinstance(p, dict) or set(p) != {'name', 'version'} or not isinstance(p['name'], str) or not isinstance(p['version'], str) for p in packages)
                or sorted((p['name'], p['version']) for p in packages) != sorted(VERSIONS.items())):
            raise ValueError('Manifest does not match locked package closure')
        declared = manifest['files']
        if not isinstance(declared, list) or not integer(len(declared), 1, FILE_CAP):
            raise ValueError('Invalid manifest file count')
        files = {}
        for f in declared:
            if (not isinstance(f, dict) or set(f) != {'path', 'size', 'sha256'}
                    or not integer(f['size'], 0, EXPANDED_CAP) or not is_hash(f['sha256'])):
                raise ValueError('Invalid manifest file entry')
            safe_relative(f['path'])
            files[f['path']] = f
        check_paths(f['path'] for f in declared)
        expanded = sum(f['size'] for f in declared)
        if expanded > EXPANDED_CAP:
            raise ValueError('Manifest expanded size exceeds cap')
        archive = directory / 'python-runtime.zip'
        assembly = lock['assembled']
        if (not integer(archive.stat().st_size, 1, ZIP_CAP) or archive.stat().st_size != assembly['size']
                or expanded != assembly['expandedSize'] or len(files) != assembly['fileCount']
                or manifest['archiveSha256'] != assembly['archiveSha256']
                or sha256_file(archive) != assembly['archiveSha256']):
            raise ValueError('Archive SHA256/size/count does not match trusted assembly')
        required_files(files, lock)
        with zipfile.ZipFile(archive) as z:
            entries = zip_entries(z)
            if len(entries) != len(z.infolist()) or {e.filename for e in entries} != set(files):
                raise ValueError('ZIP missing/unexpected files or directory entries')
            metadata = {}
            for e in entries:
                z.fp.seek(e.header_offset)
                header = z.fp.read(30)
                if len(header) != 30:
                    raise ValueError('Truncated ZIP local header')
                local = struct.unpack('<4s5H3I2H', header)
                raw_name = z.fp.read(local[9])
                encoding = 'utf-8' if e.flag_bits & 0x800 else 'cp437'
                if (local[0] != b'PK\x03\x04' or local[2] != e.flag_bits or local[3] != e.compress_type
                        or e.flag_bits & 8 or local[6:9] != (e.CRC, e.compress_size, e.file_size)
                        or raw_name.decode(encoding) != e.filename or e.orig_filename != e.filename
                        or e.header_offset + 30 + local[9] + local[10] + e.compress_size > z.start_dir):
                    raise ValueError('ZIP local/central header mismatch: ' + e.filename)
                if e.file_size != files[e.filename]['size']:
                    raise ValueError('ZIP file size mismatch: ' + e.filename)
                with z.open(e) as stream:
                    h = hashlib.sha256(); chunks = []; total = 0
                    inspect = e.filename == 'bin/python3' or e.filename.endswith(('.so', '/METADATA', '/WHEEL')) or '.so.' in e.filename
                    while True:
                        data = stream.read(65536)
                        if not data:
                            break
                        total += len(data)
                        if total > e.file_size:
                            raise ValueError('ZIP expansion exceeds declared file size')
                        h.update(data)
                        if inspect:
                            chunks.append(data)
                    if total != e.file_size or h.hexdigest() != files[e.filename]['sha256']:
                        raise ValueError('File SHA256/size mismatch: ' + e.filename)
                    if inspect:
                        data = b''.join(chunks)
                        if e.filename.endswith(('/METADATA', '/WHEEL')):
                            metadata[e.filename] = data.decode('utf-8')
                        else:
                            check_elf(data, e.filename)
            for p in lock['packages']:
                prefix = SITE + p['name'].replace('-', '_') + '-' + p['version'] + '.dist-info/'
                meta = email.parser.Parser().parsestr(metadata[prefix + 'METADATA'])
                normal = lambda name: re.sub('[-_.]+', '-', name or '').lower()
                if normal(meta['Name']) != p['name'] or meta['Version'] != p['version']:
                    raise ValueError('Dist-info does not match locked package version')
                tags = set(email.parser.Parser().parsestr(metadata[prefix + 'WHEEL']).get_all('Tag', []))
                if tags != wheel_tags(p['filename']):
                    raise ValueError('Wheel metadata does not match locked ABI/platform tags')
        return manifest
    except (OSError, KeyError, TypeError, UnicodeError, zipfile.BadZipFile, RuntimeError, struct.error) as exc:
        raise ValueError('Invalid Python bundle: ' + str(exc)) from exc


def validate_bundle(directory: pathlib.Path) -> dict:
    """Pure, offline validation against the repository's trusted Linux assembly lock."""
    return _validate_bundle(directory, read_lock(DEFAULT_LOCK))


def write_bundle(tree, output, lock):
    paths = sorted(p for p in tree.rglob('*') if p.is_file())
    check_paths(p.relative_to(tree).as_posix() for p in paths)
    if not integer(len(paths), 1, FILE_CAP) or sum(p.stat().st_size for p in paths) > EXPANDED_CAP:
        raise ValueError('Assembled runtime exceeds file/size limits')
    manifest_files = []
    with zipfile.ZipFile(output / 'python-runtime.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in paths:
            no_links(p)
            if not stat.S_ISREG(p.stat().st_mode):
                raise ValueError('Non-regular assembly input')
            name = p.relative_to(tree).as_posix()
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o600) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            info._compresslevel = 9
            with p.open('rb') as source, z.open(info, 'w') as dest:
                shutil.copyfileobj(source, dest, 65536)
            manifest_files.append(dict(path=name, size=p.stat().st_size, sha256=sha256_file(p)))
    archive = output / 'python-runtime.zip'
    if archive.stat().st_size > ZIP_CAP:
        raise ValueError('Assembled ZIP exceeds 64MiB')
    manifest = dict(schemaVersion=1, platform='linux-x64', pythonVersion=PYTHON_VERSION,
                    archive='python-runtime.zip', archiveSha256=sha256_file(archive),
                    packages=[dict(name=p['name'], version=p['version']) for p in sorted(lock['packages'], key=lambda p: p['name'])],
                    probeModules=PROBES, files=manifest_files)
    data = json.dumps(manifest, indent=2, ensure_ascii=True) + '\n'
    if len(data.encode()) > MANIFEST_CAP:
        raise ValueError('Assembled manifest exceeds cap')
    (output / 'bundle.json').write_text(data, encoding='utf-8')
    return manifest


def invoke_probe(tree, lock, manifest):
    expected = {f['path']: f for f in manifest['files']}
    actual = {p.relative_to(tree).as_posix(): p for p in tree.rglob('*') if not p.is_dir()}
    if set(actual) != set(expected):
        raise ValueError('Pre-execution tree file set mismatch')
    for name, p in actual.items():
        no_links(p)
        if not p.is_file() or p.stat().st_size != expected[name]['size'] or sha256_file(p) != expected[name]['sha256']:
            raise ValueError('Pre-execution tree hash/size mismatch: ' + name)
    entry = tree / 'bin/python3'
    entry.chmod(0o700)
    code = '''import sys,json,pathlib,importlib.metadata as m
import requests,Crypto,lxml.etree,bs4
from Crypto.Cipher import AES
root=pathlib.Path(sys.executable).resolve().parent.parent
lock=json.loads(sys.argv[1])
assert sys.version.split()[0]==lock['python']['version'],sys.version
assert sys.flags.isolated and sys.flags.dont_write_bytecode
assert all(pathlib.Path(p).resolve().is_relative_to(root) for p in sys.path),sys.path
assert all(pathlib.Path(mod.__file__).resolve().is_relative_to(root) for mod in (requests,Crypto,lxml.etree,bs4))
versions={p['name']:m.version(p['name']) for p in lock['packages']}
assert versions=={p['name']:p['version'] for p in lock['packages']},versions
assert len(AES.new(b'0'*16,AES.MODE_ECB).encrypt(b'1'*16))==16
assert lxml.etree.fromstring(b'<root/>').tag=='root'
assert bs4.BeautifulSoup('<p>ok</p>','html.parser').p.text=='ok'
print(json.dumps({'python':sys.version.split()[0],'packages':versions,'executable':str(sys.executable),'sysPath':sys.path,'isolated':bool(sys.flags.isolated)}))'''
    result = subprocess.run([str(entry), '-I', '-B', '-c', code, json.dumps(lock)],
                            cwd=tree, env={'PATH': '', 'HOME': str(tree), 'LANG': 'C.UTF-8'},
                            text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise ValueError('Native isolated probe failed: ' + result.stderr[-4000:])
    return json.loads(result.stdout)


def _publication_directory(output):
    key = hashlib.sha256(str(output).encode('utf-8')).hexdigest()
    return workspace_directory(ROOT / '.local/python-runtime-linux' / ('publish-' + key))


def _recover_publication(output, lock):
    transaction = _publication_directory(output)
    if not transaction.exists():
        return
    if {path.name for path in transaction.iterdir()} - {'bundle', 'previous'}:
        raise ValueError('Unexpected publication recovery contents: ' + str(transaction))
    for path in transaction.iterdir():
        if not no_links(path).is_dir():
            raise ValueError('Unsafe publication recovery entry: ' + str(path))
    previous = transaction / 'previous'
    if output.exists() and any(output.iterdir()):
        _validate_bundle(output, lock)
    elif previous.exists():
        _validate_bundle(previous, lock)
        if output.exists():
            no_links(output).rmdir()
        os.replace(previous, output)
    no_links(transaction)
    shutil.rmtree(transaction)


def _publish_bundle(stage, output, lock):
    transaction = _publication_directory(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    no_links(output)
    transaction.mkdir(parents=True)
    prepared = transaction / 'bundle'
    previous = transaction / 'previous'
    try:
        if transaction.stat().st_dev != output.parent.stat().st_dev:
            raise ValueError('Publication staging and output must share a filesystem')
        shutil.copytree(stage, prepared)
        _validate_bundle(prepared, lock)
        no_links(output)
        if output.exists():
            os.replace(output, previous)
        os.replace(prepared, output)
    except BaseException:
        if previous.exists() and not output.exists():
            try:
                no_links(previous)
                no_links(output)
                os.replace(previous, output)
            except BaseException as error:
                print('Previous bundle retained for recovery at ' + str(previous) + ': ' + str(error), file=sys.stderr)
        if not previous.exists():
            try:
                no_links(transaction)
                shutil.rmtree(transaction)
            except BaseException:
                pass
        else:
            print('Persistent previous bundle: ' + str(previous), file=sys.stderr)
        raise
    no_links(transaction)
    shutil.rmtree(transaction)


def build(output, cache, lock_file, offline=False):
    if sys.platform != 'linux' or platform.machine() not in ('x86_64', 'AMD64'):
        raise ValueError('Linux x86_64 native build required')
    output = workspace_directory(output)
    cache = workspace_directory(cache)
    if output == cache or output.is_relative_to(cache) or cache.is_relative_to(output):
        raise ValueError('Output and cache must not overlap')
    lock = read_lock(lock_file)
    _recover_publication(output, lock)
    if output.exists() and any(output.iterdir()):
        _validate_bundle(output, lock)
    sources = [(a, get_artifact(a, cache, offline)) for a in [lock['python']] + lock['packages']]
    scratch = workspace_directory(ROOT / '.local/python-runtime-linux')
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix='assembly-') as temp:
        tree = pathlib.Path(temp) / 'tree'; tree.mkdir()
        stage = pathlib.Path(temp) / 'bundle'; stage.mkdir()
        extract_python(sources[0][1], tree)
        for package, source in sources[1:]:
            extract_wheel(source, tree, package)
        manifest = write_bundle(tree, stage, lock)
        _validate_bundle(stage, lock)
        probe = invoke_probe(tree, lock, manifest)
        _publish_bundle(stage, output, lock)
        print(json.dumps({'archiveSha256': manifest['archiveSha256'], 'probe': probe}, ensure_ascii=True))
        return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=pathlib.Path, default=ROOT / 'runtime/python')
    parser.add_argument('--cache-dir', type=pathlib.Path, default=ROOT / '.local/python-runtime-linux/cache')
    parser.add_argument('--lock-file', type=pathlib.Path, default=DEFAULT_LOCK)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.validate_only:
            manifest = _validate_bundle(args.output_dir, read_lock(args.lock_file))
            print(json.dumps({'validated': str(args.output_dir), 'archiveSha256': manifest['archiveSha256']}))
        else:
            build(args.output_dir, args.cache_dir, args.lock_file, args.offline)
        return 0
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile, subprocess.SubprocessError) as exc:
        print('Python runtime error: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
