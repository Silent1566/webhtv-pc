import os
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TARGETS = (
    ('desktop-ci.yml', 'build-linux'),
    ('desktop-ci.yml', 'e2e-linux-trial'),
    ('desktop-release.yml', 'build-linux'),
)
APT_STEP = 'Install native build and packaging dependencies'
ACQUIRE_OPTIONS = (
    'Acquire::Retries=2',
    'Acquire::http::Timeout=30',
    'Acquire::https::Timeout=30',
)
PACKAGES = [
    'clang', 'cmake', 'ninja-build', 'pkg-config', 'libgtk-3-dev',
    'libmpv-dev', 'libnotify-dev', 'liblzma-dev', 'libstdc++-12-dev',
    'xvfb', 'xauth', 'x11-utils', 'dpkg-dev', 'fonts-noto-cjk',
]
SHELL_HARNESS = r'''
sudo() {
  [[ "$1" == apt-get ]] || return 127
  "$@"
}
apt-get() {
  printf '%s\0' "$@"
  printf '\0'
  for arg in "$@"; do
    case "$arg" in
      update) return "$APT_UPDATE_EXIT" ;;
      install) return "$APT_INSTALL_EXIT" ;;
    esac
  done
  return 127
}
'''


def apt_step(filename, job):
    document = yaml.load(
        (ROOT / '.github/workflows' / filename).read_text(),
        Loader=yaml.BaseLoader,
    )
    return next(item for item in document['jobs'][job]['steps']
                if item.get('name') == APT_STEP)


def run_apt_step(step, update_exit=0, install_exit=0):
    env = dict(os.environ, APT_UPDATE_EXIT=str(update_exit),
               APT_INSTALL_EXIT=str(install_exit))
    result = subprocess.run(
        ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
         SHELL_HARNESS + step['run']],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=5,
    )
    calls = [call.split('\0') for call in result.stdout.split('\0\0') if call]
    return result, calls


class AptBudgetTests(unittest.TestCase):
    def test_apt_steps_have_a_five_minute_budget(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                step = apt_step(filename, job)
                self.assertEqual('5', step.get('timeout-minutes'))
                self.assertNotIn('continue-on-error', step)

    def test_update_and_install_receive_bounded_acquire_options(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result, calls = run_apt_step(apt_step(filename, job))
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(2, len(calls))
                for call in calls:
                    options = [call[i + 1] for i, arg in enumerate(call)
                               if arg == '-o']
                    self.assertCountEqual(ACQUIRE_OPTIONS, options)

    def test_update_requests_failure_on_any_repository_error(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result, calls = run_apt_step(apt_step(filename, job))
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn('update', calls[0])
                self.assertIn('--error-on=any', calls[0])

    def test_install_keeps_the_native_dependency_list(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result, calls = run_apt_step(apt_step(filename, job))
                self.assertEqual(0, result.returncode, result.stderr)
                install = calls[1]
                self.assertIn('install', install)
                self.assertIn('--no-install-recommends', install)
                self.assertEqual(PACKAGES, install[install.index('-y') + 1:])

    def test_update_failure_stops_before_install(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result, calls = run_apt_step(apt_step(filename, job), update_exit=100)
                self.assertEqual(100, result.returncode, result.stderr)
                self.assertEqual(1, len(calls))
                self.assertIn('update', calls[0])

    def test_install_failure_propagates(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result, calls = run_apt_step(apt_step(filename, job), install_exit=100)
                self.assertEqual(100, result.returncode, result.stderr)
                self.assertEqual(2, len(calls))
                self.assertIn('install', calls[1])

    def test_apt_scripts_have_valid_bash_syntax(self):
        for filename, job in TARGETS:
            with self.subTest(filename=filename, job=job):
                result = subprocess.run(
                    ['bash', '-n'], input=apt_step(filename, job)['run'],
                    text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(0, result.returncode, result.stderr)


if __name__ == '__main__':
    unittest.main()
