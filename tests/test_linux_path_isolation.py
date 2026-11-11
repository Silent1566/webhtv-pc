import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/desktop-flutter'


DART_TOKEN = re.compile(
    r"""//[^\n]*|/\*.*?\*/|r?(?:'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")|[A-Za-z_]\w*|[^\s]""",
    re.DOTALL,
)
DIRECTORIES = ('config', 'data', 'cache', 'state')


def unsafe_overrides(source):
    """Check literal override maps, not runtime paths or nonliteral helpers."""
    matches = [match for match in DART_TOKEN.finditer(source)
               if not match.group().startswith(('//', '/*'))]
    tokens = [match.group() for match in matches]
    violations = []
    for start in range(len(tokens) - 3):
        if tokens[start:start + 4] != ['AppPaths', '.', 'resolve', '(']:
            continue
        index = start + 4
        parentheses = 1
        while index < len(tokens) and parentheses:
            if parentheses == 1 and tokens[index:index + 2] == ['overrides', ':']:
                break
            if tokens[index] == '(':
                parentheses += 1
            elif tokens[index] == ')':
                parentheses -= 1
            index += 1
        if not parentheses or index >= len(tokens):
            continue
        index += 2
        if tokens[index:index + 1] == ['const']:
            index += 1
        if tokens[index:index + 1] == ['<']:
            while index < len(tokens) and tokens[index] != '>':
                index += 1
            index += 1
        if tokens[index:index + 1] != ['{']:
            continue
        depth = 1
        keys = set()
        index += 1
        while index < len(tokens) and depth:
            token = tokens[index]
            if token == '{':
                depth += 1
            elif token == '}':
                depth -= 1
            elif depth == 1 and token[0] in "'\"" and tokens[index + 1:index + 2] == [':']:
                keys.add(token[1:-1])
            index += 1
        missing = [key for key in DIRECTORIES if key not in keys]
        reasons = []
        if missing:
            reasons.append('missing ' + ', '.join(missing))
        for key in ('roaming', 'local', 'log'):
            if key in keys:
                reasons.append(f'unsupported {key} key')
        if reasons:
            line = source.count('\n', 0, matches[start].start()) + 1
            violations.append((line, '; '.join(reasons)))
    return violations


class PathIsolationDetectorTests(unittest.TestCase):
    def test_rejects_windows_only_override_map(self):
        source = "AppPaths.resolve(overrides: {'roaming': temp.path, 'local': temp.path})"
        self.assertEqual([(1, 'missing config, data, cache, state; unsupported roaming key; '
                             'unsupported local key')], unsafe_overrides(source))

    def test_rejects_unsupported_log_key(self):
        source = """AppPaths.resolve(overrides: {
          'config': dir.path, 'data': dir.path, 'cache': dir.path, 'log': dir.path,
        })"""
        self.assertEqual([(1, 'missing state; unsupported log key')], unsafe_overrides(source))

    def test_accepts_complete_direct_override_map(self):
        source = """AppPaths.resolve(overrides: {
          'config': '${temp.path}/config', 'data': p.join(temp.path, 'data'),
          'cache': '${temp.path}/cache', 'state': temp.path,
        })"""
        self.assertEqual([], unsafe_overrides(source))

    def test_rejects_xdg_only_override_map(self):
        source = """AppPaths.resolve(overrides: {
          "xdgConfig": dir.path, "xdgData": dir.path,
          "xdgCache": dir.path, "xdgState": dir.path,
        })"""
        self.assertEqual([(1, 'missing config, data, cache, state')], unsafe_overrides(source))

    def test_rejects_obsolete_keys_even_with_complete_direct_map(self):
        direct = "'config': root, 'data': root, 'cache': root, 'state': root"
        for key in ('roaming', 'local', 'log'):
            with self.subTest(key=key):
                source = f"AppPaths.resolve(overrides: {{{direct}, '{key}': root}})"
                self.assertEqual([(1, f'unsupported {key} key')], unsafe_overrides(source))
        source = f"AppPaths.resolve(overrides: {{{direct}, 'roaming': root, 'local': root}})"
        self.assertEqual([(1, 'unsupported roaming key; unsupported local key')],
                         unsafe_overrides(source))

    def test_accepts_unrelated_extra_key_with_complete_direct_map(self):
        source = """AppPaths.resolve(overrides: {
          'config': root, 'data': root, 'cache': root, 'state': root,
          'fixtureMarker': root,
        })"""
        self.assertEqual([], unsafe_overrides(source))

    def test_accepts_typed_const_map_with_comments(self):
        source = """AppPaths.resolve(appName: fixtureName(), overrides: const <String, String>{
          'config': root, 'data': root, // 'log': ignored,
          'cache': root, 'state': root,
        })"""
        self.assertEqual([], unsafe_overrides(source))

    def test_rejects_legacy_map_after_other_arguments(self):
        source = "AppPaths.resolve(appName: fixtureName(), overrides: {'local': root})"
        self.assertEqual([(1, 'missing config, data, cache, state; unsupported local key')],
                         unsafe_overrides(source))

    def test_ignores_comments_strings_and_nonliteral_maps(self):
        source = """// AppPaths.resolve(overrides: {'log': temp.path})
        /* AppPaths.resolve(overrides: {'roaming': temp.path}) */
        final text = "AppPaths.resolve(overrides: {'log': temp.path})";
        AppPaths.resolve(overrides: isolatedPaths);
        OtherPaths.resolve(overrides: {'log': temp.path});
        """
        self.assertEqual([], unsafe_overrides(source))

    def test_reports_each_call_at_its_source_line(self):
        source = """final first = AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path});
        final second = AppPaths.resolve(overrides: {'config': temp.path});
        """
        self.assertEqual([
            (1, 'missing config, data, cache, state; unsupported roaming key; unsupported local key'),
            (3, 'missing data, cache, state'),
        ], unsafe_overrides(source))


class FlutterTestPathIsolationTests(unittest.TestCase):
    def test_literal_overrides_isolate_every_platform_directory(self):
        violations = []
        for tree in ('test', 'integration_test'):
            for path in sorted((APP / tree).rglob('*.dart')):
                for line, reason in unsafe_overrides(path.read_text()):
                    violations.append(f'{path.relative_to(ROOT)}:{line}: {reason}')
        shown = violations[:20]
        if len(violations) > len(shown):
            shown.append(f'... {len(violations) - len(shown)} more unsafe calls')
        if violations:
            self.fail('\n' + '\n'.join([
                f'{len(violations)} unsafe AppPaths.resolve literal override maps.',
                'Provide all four direct config/data/cache/state keys; reject roaming/local/log. XDG-only is not portable.',
                *shown,
            ]))


if __name__ == '__main__':
    unittest.main()
