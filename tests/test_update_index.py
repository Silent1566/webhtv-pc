import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/generate_update_index.py'
REPOSITORY = 'Silent1566/webhtv-pc'
TAG = 'v0.1.0-202611231630'
SHA = '0123456789abcdef' * 4


def asset(name, tag=TAG, digest='sha256:' + SHA, repository=REPOSITORY):
    return dict(name=name, size=123, digest=digest,
                browser_download_url=f'https://github.com/{repository}/releases/download/{tag}/{name}')


def release(tag=TAG, repository=REPOSITORY):
    version = tag[1:].rsplit('-', 1)[0]
    return dict(tag_name=tag, name=f'WebHTV PC {version}',
                body='# Full notes\n\n中文说明\n- Fix [details](https://example.com/issue)\n' * 30,
                html_url=f'https://github.com/{repository}/releases/tag/{tag}',
                published_at='2026-11-23T08:30:00Z', prerelease='-beta-' in tag, draft=False,
                assets=[asset(f'webhtv-pc-{version}-{suffix}', tag, repository=repository)
                        for suffix in ('windows-x64.zip', 'linux-x64.AppImage', 'linux-x64.deb')]
                       + [asset('SHA256SUMS.txt', tag, digest=None, repository=repository),
                          asset('release-info.json', tag, repository=repository),
                          asset('linux-release-info.json', tag, repository=repository)])


GH_STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with Path(os.environ['GH_LOG']).open('a') as output:
    output.write(json.dumps(args) + '\n')
if args[:1] == ['api']:
    if os.environ.get('GH_FETCH_FAIL'):
        raise SystemExit(1)
    print(Path(os.environ['GH_FIXTURE']).read_text())
elif args[:2] == ['release', 'view']:
    raise SystemExit(0 if os.environ.get('GH_INDEX_EXISTS') else 1)
elif args[:2] == ['release', 'create']:
    pass
elif args[:2] == ['release', 'upload']:
    source = Path(args[3])
    document = json.loads(source.read_text())
    assert isinstance(document, list) and document
    Path(os.environ['GH_PUBLISHED']).write_text(source.read_text())
else:
    raise SystemExit('unexpected gh command: ' + repr(args))
'''


class UpdateIndexTests(unittest.TestCase):
    def run_cli(self, document, *, raw=False, repository=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source = root / 'source.json'
        output = root / 'releases.json'
        source.write_text(document if raw else json.dumps(document), encoding='utf-8')
        output.write_text('previous valid index', encoding='utf-8')
        command = [sys.executable, str(SCRIPT), '--releases-json', str(source), '--output', str(output)]
        if repository is not None:
            command += ['--repository', repository]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        return result, output

    def assert_rejected(self, document, **kwargs):
        result, output = self.run_cli(document, **kwargs)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('previous valid index', output.read_text())
        self.assertIn('error:', result.stderr.lower())

    def test_preserves_release_notes_identity_and_supported_assets(self):
        stable = release()
        beta = release('v0.2.0-beta-202611241630')
        # Legacy API releases have no asset digest; SHA256SUMS remains usable.
        for item in beta['assets']:
            item.pop('digest')
        result, output = self.run_cli([stable, beta])
        self.assertEqual(0, result.returncode, result.stderr)
        document = json.loads(output.read_text())
        self.assertEqual([stable['tag_name'], beta['tag_name']], [r['tag_name'] for r in document])
        for source, actual in zip((stable, beta), document):
            for field in ('tag_name', 'name', 'body', 'html_url', 'published_at', 'prerelease', 'draft'):
                self.assertEqual(source[field], actual[field])
            self.assertEqual(source['assets'][:4], actual['assets'])
        self.assertNotIn('release-info.json', output.read_text())

    def test_accepts_paginated_slurp_and_excludes_drafts_index_and_old_tags(self):
        draft = dict(tag_name=TAG, draft=True)
        channel = dict(tag_name='update-channel', draft=False)
        old = dict(tag_name='v0.0.1', draft=False)
        stable = release()
        result, output = self.run_cli([[draft, channel, old], [stable]])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([TAG], [r['tag_name'] for r in json.loads(output.read_text())])

    def test_keeps_up_to_thirty_normal_records_in_api_order(self):
        releases = [release(f'v0.1.{number}-202611231630') for number in range(35)]
        result, output = self.run_cli(releases)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([r['tag_name'] for r in releases[:30]],
                         [r['tag_name'] for r in json.loads(output.read_text())])

    def test_explicit_repository_requires_matching_public_urls(self):
        result, output = self.run_cli([release(repository='Example/project')], repository='Example/project')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('/Example/project/releases/', output.read_text())
        for repository in ('../bad', 'https://github.com/a/b', 'a/b/c', 'a/b?token=secret'):
            with self.subTest(repository=repository):
                self.assert_rejected([release()], repository=repository)

    def test_rejects_malformed_json_and_empty_or_nonrelease_documents(self):
        for raw in ('not JSON', '<html>Bad Gateway</html>', '{}', 'null', '[]', '[[]]',
                    '[123]', '[{}, []]', '[{"tag_name": "update-channel"}]',
                    '[NaN]', '[{"draft":false,"draft":true}]'):
            with self.subTest(raw=raw):
                self.assert_rejected(raw, raw=True)

    def test_requires_real_pipeline_version_tags_and_calendar_dates(self):
        for tag in ('v1.0.0-202602301200', 'v1.0.0-202611232460', 'v1.0.0-000011231630',
                    'v1.0.0-rc-202611231630', '1.0.0-202611231630', 'v1.0.0-202611231630/../x'):
            with self.subTest(tag=tag):
                self.assert_rejected([release(tag)])

    def test_rejects_malformed_release_fields(self):
        for field, value in (('draft', 'false'), ('prerelease', 0), ('tag_name', 123),
                             ('name', {}), ('body', []), ('published_at', None),
                             ('published_at', '2026-02-30T00:00:00Z'),
                             ('published_at', '2026-11-23'),
                             ('published_at', '2026-11-23T08:30:00+01:99'), ('assets', {})):
            source = release()
            source[field] = value
            with self.subTest(field=field, value=value):
                self.assert_rejected([source])

    def test_rejects_unsafe_or_wrong_repository_release_and_asset_urls(self):
        for field in ('html_url', 'browser_download_url'):
            for url in ('http://github.com/' + REPOSITORY + '/releases/tag/' + TAG,
                        'https://github.com/other/project/releases/tag/' + TAG,
                        'https://user:pass@github.com/' + REPOSITORY + '/releases/tag/' + TAG,
                        'https://github.com:444/' + REPOSITORY + '/releases/tag/' + TAG,
                        'https://github.com/' + REPOSITORY + '/releases/download/../' + TAG,
                        'https://github.com/' + REPOSITORY + '/releases/download/%2e%2e/' + TAG):
                source = release()
                target = source if field == 'html_url' else source['assets'][0]
                target[field] = url
                with self.subTest(field=field, url=url):
                    self.assert_rejected([source])
        for suffix in ('?token=secret', '#fragment', '/extra', '%2f..%2fother', r'\bad'):
            source = release()
            source['assets'][0]['browser_download_url'] += suffix
            with self.subTest(suffix=suffix):
                self.assert_rejected([source])
        source = release()
        source['assets'][0]['browser_download_url'] = source['assets'][0]['browser_download_url'].replace(TAG, 'latest')
        self.assert_rejected([source])

    def test_rejects_bad_sizes_digests_names_and_incomplete_assets(self):
        changes = [('size', value) for value in (0, -1, True, 1.5, '123', 2**63)]
        changes += [('digest', value) for value in ('', 'sha256:bad', 'sha512:' + SHA, SHA, 123)]
        changes += [('name', value) for value in ('../package.zip', 'dir/package.zip', r'dir\package.zip',
                                                  'webhtv-pc-9.9.9-windows-x64.zip',
                                                  'webhtv-pc-0.1.0-beta-windows-x64.zip')]
        changes += [('state', 'new')]
        for field, value in changes:
            source = release()
            source['assets'][0][field] = value
            if field == 'name':
                source['assets'][0]['browser_download_url'] = (
                    f'https://github.com/{REPOSITORY}/releases/download/{TAG}/{value}')
            with self.subTest(field=field, value=value):
                self.assert_rejected([source])
        for assets in ([], [asset('SHA256SUMS.txt')], release()['assets'][:3],
                       release()['assets'] + [copy.deepcopy(release()['assets'][0])], [123]):
            source = release()
            source['assets'] = assets
            with self.subTest(assets=assets):
                self.assert_rejected([source])

    def test_rejects_duplicate_tags_and_invalid_tail_beyond_retention_limit(self):
        self.assert_rejected([release(), release()])
        sources = [release(f'v0.1.{number}-202611231630') for number in range(31)]
        sources[-1]['assets'][0]['digest'] = 'sha256:bad'
        self.assert_rejected(sources)

    def test_refuses_index_larger_than_client_metadata_bound_without_truncating_notes(self):
        source = release()
        source['body'] = 'x' * (2 * 1024 * 1024)
        self.assert_rejected([source])

    def test_supports_single_platform_and_nullable_github_notes(self):
        source = release()
        source['name'] = None
        source['body'] = None
        source['assets'] = [source['assets'][0], source['assets'][3]]
        result, output = self.run_cli([source])
        self.assertEqual(0, result.returncode, result.stderr)
        document = json.loads(output.read_text())
        self.assertEqual(2, len(document[0]['assets']))
        self.assertIsNone(document[0]['name'])
        self.assertIsNone(document[0]['body'])


class UpdateIndexWorkflowTests(unittest.TestCase):
    def workflow(self):
        return yaml.load((ROOT / '.github/workflows/desktop-release.yml').read_text(), Loader=yaml.BaseLoader)

    def index_step(self):
        matches = [step for step in self.workflow()['jobs']['publish']['steps']
                   if step['name'] == 'Publish static update index']
        self.assertEqual(1, len(matches), 'missing post-publish static update index step')
        return matches[0]

    def test_yaml_keeps_serial_publish_and_success_only_index_condition(self):
        document = self.workflow()
        self.assertEqual({'group': 'desktop-release', 'cancel-in-progress': 'false'}, document['concurrency'])
        self.assertEqual('write', document['permissions']['contents'])
        steps = document['jobs']['publish']['steps']
        publish = next(step for step in steps if step['name'] == 'Publish GitHub Release')
        index = self.index_step()
        self.assertEqual('publish_release', publish['id'])
        self.assertGreater(steps.index(index), steps.index(publish))
        self.assertEqual(
            "${{ inputs.publish_release && steps.publish_release.outcome == 'success' }}", index['if'])
        self.assertEqual('${{ github.token }}', index['env']['GH_TOKEN'])
        self.assertEqual('${{ github.repository }}', index['env']['GH_REPO'])

    def run_index_step(self, fixture, *, exists=False, fetch_fail=False):
        step = self.index_step()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / 'scripts').mkdir()
        self.assertTrue(SCRIPT.exists(), 'index generator is missing')
        shutil.copy2(SCRIPT, root / 'scripts/generate_update_index.py')
        (root / 'bin').mkdir()
        gh = root / 'bin/gh'
        gh.write_text(GH_STUB)
        gh.chmod(0o755)
        source = root / 'fixture.json'
        source.write_text(json.dumps(fixture))
        published = root / 'published.json'
        published.write_text('previous valid remote index')
        log = root / 'gh.log'
        env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                   GH_REPO=REPOSITORY, GH_TOKEN='offline-stub', GH_FIXTURE=str(source), GH_LOG=str(log),
                   GH_PUBLISHED=str(published), GITHUB_SHA='a' * 40)
        if exists:
            env['GH_INDEX_EXISTS'] = '1'
        if fetch_fail:
            env['GH_FETCH_FAIL'] = '1'
        result = subprocess.run(['bash', '-c', step['run']], cwd=root, env=env,
                                capture_output=True, text=True)
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, commands, published

    def test_executes_actual_workflow_shell_with_paginated_offline_gh(self):
        for exists in (False, True):
            with self.subTest(exists=exists):
                result, commands, published = self.run_index_step([[release()]], exists=exists)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(TAG, json.loads(published.read_text())[0]['tag_name'])
                api = commands[0]
                self.assertEqual('api', api[0])
                self.assertIn(f'repos/{REPOSITORY}/releases?per_page=100', api)
                self.assertIn('--paginate', api)
                self.assertIn('--slurp', api)
                creates = [command for command in commands if command[:2] == ['release', 'create']]
                self.assertEqual(0 if exists else 1, len(creates))
                if creates:
                    self.assertIn('update-channel', creates[0])
                    self.assertIn('--prerelease', creates[0])
                    self.assertIn('--latest=false', creates[0])
                uploads = [command for command in commands if command[:2] == ['release', 'upload']]
                self.assertEqual(1, len(uploads))
                self.assertEqual('update-channel', uploads[0][2])
                self.assertEqual('releases.json', Path(uploads[0][3]).name)
                self.assertIn('--clobber', uploads[0])

    def test_invalid_source_or_failed_fetch_never_reaches_remote_mutation(self):
        for source, fetch_fail in (([], False), ([[release()]], True)):
            with self.subTest(fetch_fail=fetch_fail):
                result, commands, published = self.run_index_step(source, fetch_fail=fetch_fail)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual('previous valid remote index', published.read_text())
                self.assertEqual([], [command for command in commands if command[:1] == ['release']])

    def test_existing_ci_discovery_includes_offline_index_suite(self):
        document = yaml.load((ROOT / '.github/workflows/desktop-ci.yml').read_text(), Loader=yaml.BaseLoader)
        commands = [step.get('run', '') for step in document['jobs']['build-linux']['steps']]
        self.assertIn("python3 -m unittest discover -s tests -p 'test_*.py'", commands)


if __name__ == '__main__':
    unittest.main()
