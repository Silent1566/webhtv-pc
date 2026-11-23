#!/usr/bin/env python3
"""Validate authenticated GitHub release-list JSON into the public update index."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import tempfile


TAG_PATTERN = re.compile(r'v([0-9]+\.[0-9]+\.[0-9]+)(-beta)?-([0-9]{12})')
DIGEST_PATTERN = re.compile(r'sha256:[0-9a-fA-F]{64}')
PACKAGE_SUFFIXES = ('-windows-x64.zip', '-linux-x64.AppImage', '-linux-x64.deb')
MAX_RELEASES = 30
MAX_INDEX_BYTES = 2 * 1024 * 1024


def fail(message):
    raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def reject_constant(value):
    fail(f'invalid JSON constant: {value}')


def validate_repository(repository):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*', repository):
        fail('repository must be an owner/name pair')


def validate_published_at(value):
    if not isinstance(value, str) or not re.fullmatch(
            r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
            r'(?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])', value):
        fail('published_at must be an RFC3339 timestamp')
    datetime.fromisoformat(value.replace('Z', '+00:00'))


def release_assets(raw, repository, tag, version):
    if not isinstance(raw, list):
        fail(f'{tag}: assets must be an array')
    packages = {f'webhtv-pc-{version}{suffix}' for suffix in PACKAGE_SUFFIXES}
    selected = []
    names = set()
    for item in raw:
        if not isinstance(item, dict):
            fail(f'{tag}: asset must be an object')
        name = item.get('name')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
            fail(f'{tag}: unsafe asset name')
        if name in names:
            fail(f'{tag}: duplicate asset name: {name}')
        names.add(name)
        expected_url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
        if item.get('browser_download_url') != expected_url:
            fail(f'{tag}: asset URL must be the public tag-pinned repository URL')
        size = item.get('size')
        if type(size) is not int or not 0 < size < 2**63:
            fail(f'{tag}: asset size must be a positive signed 64-bit integer')
        digest = item.get('digest')
        if digest is not None and (not isinstance(digest, str) or not DIGEST_PATTERN.fullmatch(digest)):
            fail(f'{tag}: invalid SHA-256 asset digest')
        if item.get('state', 'uploaded') != 'uploaded':
            fail(f'{tag}: asset is not uploaded')
        if name.endswith(PACKAGE_SUFFIXES) and name not in packages:
            fail(f'{tag}: package filename does not match release version/channel')
        if name in packages or name == 'SHA256SUMS.txt':
            asset = {key: item[key] for key in ('name', 'size', 'browser_download_url')}
            if 'digest' in item:
                asset['digest'] = digest
            selected.append(asset)
    if not names.intersection(packages) or 'SHA256SUMS.txt' not in names:
        fail(f'{tag}: package and SHA256SUMS.txt assets are required')
    return selected


def generate_index(document, repository):
    validate_repository(repository)
    if not isinstance(document, list):
        fail('release source must be an array or a slurped array of pages')
    if document and all(isinstance(page, list) for page in document):
        document = [item for page in document for item in page]
    releases = []
    tags = set()
    for item in document:
        if not isinstance(item, dict):
            fail('release entry must be an object')
        if item.get('tag_name') == 'update-channel' or item.get('draft') is True:
            continue
        if type(item.get('draft')) is not bool or not isinstance(item.get('tag_name'), str):
            fail('release entry requires a boolean draft and string tag_name')
        tag = item['tag_name']
        match = TAG_PATTERN.fullmatch(tag)
        if match is None:
            continue
        stamp = match[3]
        datetime(int(stamp[:4]), int(stamp[4:6]), int(stamp[6:8]), int(stamp[8:10]), int(stamp[10:12]))
        if tag in tags:
            fail(f'duplicate release tag: {tag}')
        tags.add(tag)
        if type(item.get('prerelease')) is not bool:
            fail(f'{tag}: prerelease must be a boolean')
        for field in ('name', 'body'):
            if item.get(field) is not None and not isinstance(item[field], str):
                fail(f'{tag}: {field} must be a string or null')
        if item.get('html_url') != f'https://github.com/{repository}/releases/tag/{tag}':
            fail(f'{tag}: release URL must be the public repository tag URL')
        validate_published_at(item.get('published_at'))
        assets = release_assets(item.get('assets'), repository, tag, match[1] + (match[2] or ''))
        record = {field: item.get(field) for field in (
            'tag_name', 'name', 'body', 'html_url', 'published_at', 'prerelease', 'draft')}
        record['assets'] = assets
        releases.append(record)
    if not releases:
        fail('release source contains no normal published releases')
    encoded = (json.dumps(releases[:MAX_RELEASES], ensure_ascii=False, allow_nan=False, indent=2) + '\n').encode('utf-8')
    if len(encoded) > MAX_INDEX_BYTES:
        fail('release index exceeds the client 2 MiB metadata limit; notes will not be truncated')
    return encoded


def atomic_write(output, content):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=f'.{output.name}.', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--releases-json', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--repository', default='Silent1566/webhtv-pc')
    args = parser.parse_args()
    try:
        document = json.loads(args.releases_json.read_text(encoding='utf-8'),
                              object_pairs_hook=unique_object, parse_constant=reject_constant)
        content = generate_index(document, args.repository)
        atomic_write(args.output, content)
    except (OSError, ValueError, RecursionError) as error:
        parser.exit(1, f'error: {error}\n')
    print(f'Validated update index: {args.output} ({len(content)} bytes)')


if __name__ == '__main__':
    main()
