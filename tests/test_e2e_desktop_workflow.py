import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/desktop-ci.yml'
E2E_STEP = 'Run MVP-A e2e flow under xvfb'

# Exercise the actual workflow shell without installing a WM or building Flutter.
COMMAND_STUB = r'''
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

root = Path(os.environ['HARNESS_ROOT'])
command = Path(sys.argv[0]).name
mode = os.environ['WM_MODE']
args = sys.argv[1:]

def record(event, **fields):
    with (root / 'events').open('a') as log:
        log.write(json.dumps(dict(event=event, display=os.environ.get('DISPLAY'),
                                  args=args, **fields)) + '\n')

if command == 'xvfb-run':
    record('xvfb.start')
    if args[0] != '-a':
        sys.exit(96)
    env = dict(os.environ, DISPLAY=':91')
    result = subprocess.run(args[1:], env=env)
    record('xvfb.exit', code=result.returncode)
    sys.exit(result.returncode)

if command == 'openbox':
    (root / 'wm.pid').write_text(str(os.getpid()))
    def stop(signum, frame):
        record('wm.stop', signal=signum)
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    record('wm.start')
    if mode == 'dead':
        sys.exit(32)
    while True:
        signal.pause()

if command == 'flutter':
    record('flutter')
    if os.environ.get('FLUTTER_SIGNAL'):
        os.kill(os.getppid(), int(os.environ['FLUTTER_SIGNAL']))
    sys.exit(int(os.environ['FLUTTER_EXIT']))

sys.exit(94)
'''

XPROP_STUB = r'''#!/bin/bash
if (( $# == 2 )); then
  printf '{"event":"probe","display":"%s","args":["%s","%s"]}\n' \
    "$DISPLAY" "$1" "$2" >> "$HARNESS_ROOT/events"
else
  printf '{"event":"probe","display":"%s","args":["%s","%s","%s"]}\n' \
    "$DISPLAY" "$1" "$2" "$3" >> "$HARNESS_ROOT/events"
fi
[[ $WM_MODE != probe-error ]] || exit 1
case "$*" in
  '-root _NET_SUPPORTING_WM_CHECK')
    count=0
    if [[ -f $HARNESS_ROOT/checks ]]; then read -r count < "$HARNESS_ROOT/checks"; fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$HARNESS_ROOT/checks"
    if [[ ! -f $HARNESS_ROOT/wm.pid || $WM_MODE == missing || $WM_MODE == dead ]] \
      || [[ $WM_MODE == delayed && $count -lt 3 ]]; then
      echo '_NET_SUPPORTING_WM_CHECK: no such atom on any window.'
    elif [[ $WM_MODE == zero ]]; then
      echo '_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x0'
    else
      echo '_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x100'
    fi
    ;;
  '-id '*' _NET_SUPPORTING_WM_CHECK')
    window=$2
    if [[ $WM_MODE == mismatched ]]; then window=0x1000; fi
    echo "_NET_SUPPORTING_WM_CHECK(WINDOW): window id # $window"
    ;;
  '-root _NET_SUPPORTED')
    if [[ $WM_MODE == unsupported ]]; then
      echo '_NET_SUPPORTED(ATOM) = _NET_WM_STATE'
    else
      echo '_NET_SUPPORTED(ATOM) = _NET_WM_STATE, _NET_WM_STATE_FULLSCREEN'
    fi
    ;;
  *) exit 95 ;;
esac
'''


def workflow():
    return yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)


def e2e_step():
    return next(item for item in workflow()['jobs']['e2e-linux-trial']['steps']
                if item.get('name') == E2E_STEP)


class E2EDesktopWorkflowTests(unittest.TestCase):
    def run_step(self, mode='ready', flutter_exit=0, flutter_signal=None):
        with tempfile.TemporaryDirectory(prefix='webhtv-e2e-shell-', dir='/var/tmp') as directory:
            root = Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            for name in ('xvfb-run', 'openbox', 'xprop', 'flutter', 'sleep'):
                target = binary / name
                if name == 'xprop':
                    target.write_text(XPROP_STUB)
                elif name == 'sleep':
                    target.write_text('#!/bin/sh\nexec /bin/sleep 0.001\n')
                else:
                    target.write_text(f'#!{sys.executable}\n' + textwrap.dedent(COMMAND_STUB))
                target.chmod(0o755)
            env = dict(os.environ, HARNESS_ROOT=str(root), WM_MODE=mode,
                       FLUTTER_EXIT=str(flutter_exit), DISPLAY=':host',
                       PATH=str(binary) + os.pathsep + os.environ['PATH'])
            env.update(e2e_step().get('env', {}))
            env.pop('FLUTTER_SIGNAL', None)
            if flutter_signal is not None:
                env['FLUTTER_SIGNAL'] = str(flutter_signal)
            process = subprocess.Popen(
                ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                 e2e_step()['run']], cwd=ROOT, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(timeout=30)
                events_path = root / 'events'
                events = [json.loads(line) for line in events_path.read_text().splitlines()]
                pid_file = root / 'wm.pid'
                wm_alive = False
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), 0)
                        wm_alive = True
                    except ProcessLookupError:
                        pass
                return process.returncode, stdout, stderr, events, wm_alive
            finally:
                # A broken cleanup must fail the assertion, not leave a test WM behind.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate(timeout=5)

    def test_trial_stays_non_blocking_without_hiding_step_failure(self):
        job = workflow()['jobs']['e2e-linux-trial']
        self.assertEqual('true', job['continue-on-error'])
        self.assertNotIn('continue-on-error', e2e_step())
        self.assertEqual('x11', e2e_step()['env']['GDK_BACKEND'])
        self.assertEqual('apps/desktop-flutter', e2e_step()['working-directory'])

    def test_e2e_script_has_valid_bash_syntax(self):
        result = subprocess.run(['bash', '-n'], input=e2e_step()['run'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_waits_for_ewmh_in_same_display_before_real_flutter_command(self):
        code, _, stderr, events, alive = self.run_step(mode='delayed')
        self.assertEqual(0, code, stderr)
        names = [event['event'] for event in events]
        self.assertEqual(1, names.count('wm.start'), events)
        self.assertEqual(1, names.count('xvfb.start'), events)
        self.assertEqual(1, names.count('flutter'), events)
        flutter = next(event for event in events if event['event'] == 'flutter')
        self.assertEqual(['test', 'integration_test/mvp_a_flow_test.dart', '-d', 'linux'],
                         flutter['args'])
        before_flutter = events[:names.index('flutter')]
        root_checks = [event for event in before_flutter
                       if event['event'] == 'probe'
                       and event['args'] == ['-root', '_NET_SUPPORTING_WM_CHECK']]
        self.assertGreaterEqual(len(root_checks), 3, events)
        self.assertTrue(any(event.get('args') == ['-id', '0x100', '_NET_SUPPORTING_WM_CHECK']
                            for event in before_flutter), events)
        self.assertTrue(any(event.get('args') == ['-root', '_NET_SUPPORTED']
                            for event in before_flutter), events)
        self.assertLess(names.index('wm.start'), names.index('flutter'))
        self.assertLess(names.index('flutter'), names.index('wm.stop'))
        self.assertLess(names.index('wm.stop'), names.index('xvfb.exit'))
        for event in events:
            if event['event'] in ('wm.start', 'probe', 'flutter', 'wm.stop'):
                self.assertEqual(':91', event['display'], event)
        self.assertFalse(alive, events)

    def test_flutter_failure_keeps_original_exit_code_and_reaps_wm(self):
        code, _, stderr, events, alive = self.run_step(flutter_exit=37)
        self.assertEqual(37, code, stderr)
        self.assertIn('wm.stop', [event['event'] for event in events])
        self.assertFalse(alive, events)

    def test_invalid_ewmh_readiness_never_starts_flutter_and_reaps_wm(self):
        for mode in ('missing', 'zero', 'mismatched', 'unsupported', 'probe-error'):
            with self.subTest(mode=mode):
                code, _, stderr, events, alive = self.run_step(mode=mode)
                self.assertNotEqual(0, code, stderr)
                self.assertNotIn('flutter', [event['event'] for event in events])
                self.assertIn('wm.stop', [event['event'] for event in events])
                self.assertFalse(alive, events)

    def test_wm_early_exit_fails_without_starting_flutter(self):
        code, _, stderr, events, alive = self.run_step(mode='dead')
        self.assertNotEqual(0, code, stderr)
        self.assertNotIn('flutter', [event['event'] for event in events])
        self.assertFalse(alive, events)

    def test_termination_reaps_wm_and_preserves_signal_exit(self):
        code, _, stderr, events, alive = self.run_step(flutter_signal=signal.SIGTERM)
        self.assertEqual(143, code, stderr)
        self.assertIn('wm.stop', [event['event'] for event in events])
        self.assertFalse(alive, events)


if __name__ == '__main__':
    unittest.main()
