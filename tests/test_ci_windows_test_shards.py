import copy
import shutil
import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/desktop-ci.yml"
REQUIRED_CHECK = "Analyze, test, build and package (Windows x64)"


def load_workflow():
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def check_matrix_contract(test, job):
    test.assertEqual("windows-latest", job["runs-on"])
    test.assertEqual("60", job["timeout-minutes"])
    test.assertEqual({"fail-fast": "false", "matrix": {"shardIndex": ["0", "1", "2", "3"]}},
                     job.get("strategy"))
    test.assertNotIn("if", job)
    test.assertNotIn("continue-on-error", job)
    test.assertIn("${{ matrix.shardIndex }}", job["name"])
    test.assertNotEqual(REQUIRED_CHECK, job["name"])
    names = [job["name"].replace("${{ matrix.shardIndex }}", str(index)) for index in range(4)]
    test.assertEqual(4, len(set(names)))
    unit = next(step for step in job["steps"] if step["name"] == "Unit tests")
    test.assertEqual("45", unit["timeout-minutes"])
    test.assertEqual("apps/desktop-flutter", unit["working-directory"])
    test.assertNotIn("if", unit)
    test.assertNotIn("continue-on-error", unit)
    commands = [line.strip() for line in unit["run"].splitlines()
                if line.strip() and not line.lstrip().startswith("#")]
    test.assertEqual([
        "& ../../scripts/flutter_test_diagnostics_windows.ps1 -TotalShards 4 -ShardIndex ${{ matrix.shardIndex }}",
        "exit $LASTEXITCODE",
    ], commands[-2:])
    test.assertNotRegex(unit["run"], r"(?i)--(?:name|plain-name|exclude|tags|skip)|flutter test|Get-ChildItem.*test")


def check_gate_contract(test, jobs):
    gates = [job for job in jobs.values() if job.get("name") == REQUIRED_CHECK]
    test.assertEqual(1, len(gates), "The original required-check name must occur exactly once")
    gate = gates[0]
    test.assertEqual(["build-windows"], gate["needs"])
    test.assertEqual("always()", gate["if"])
    test.assertNotIn("strategy", gate)
    test.assertNotIn("continue-on-error", gate)
    test.assertEqual(1, len(gate["steps"]))
    step = gate["steps"][0]
    test.assertNotIn("if", step)
    test.assertNotIn("continue-on-error", step)
    test.assertEqual("pwsh", step["shell"])
    test.assertRegex(step["run"], r"if \(\s*'\$\{\{ needs\.build-windows\.result \}\}' -ne 'success'\s*\)")
    test.assertRegex(step["run"], r"(?m)^\s*throw ")
    test.assertNotRegex(step["run"], r"(?i)exit 0|continue|catch")
    return step["run"]


class WindowsNativeShardWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.document = load_workflow()
        self.job = self.document["jobs"]["build-windows"]

    def test_original_required_check_is_an_always_running_strict_matrix_gate(self):
        check_gate_contract(self, self.document["jobs"])

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required for gate execution")
    def test_gate_returns_failure_for_failure_cancellation_and_skipped_matrix(self):
        source = check_gate_contract(self, self.document["jobs"])
        for result in ("success", "failure", "cancelled", "skipped", "", "unknown"):
            with self.subTest(result=result):
                command = source.replace("${{ needs.build-windows.result }}", result)
                execution = subprocess.run(
                    [shutil.which("pwsh"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
                    capture_output=True, text=True, encoding="utf-8", timeout=30,
                )
                self.assertEqual(result == "success", execution.returncode == 0, execution.stderr)

    def test_shard_artifacts_are_unique_and_packaging_publishes_only_shard_zero(self):
        steps = {step["name"]: step for step in self.job["steps"]}
        artifact_names = []
        for label, prefix in (
            ("Upload Windows unit test diagnostics", "webhtv-pc-test-diagnostics-windows-x64"),
            ("Upload Windows unit test coverage", "webhtv-pc-coverage-windows-x64"),
        ):
            step = steps[label]
            self.assertEqual("always()", step["if"])
            self.assertEqual("actions/upload-artifact@v4", step["uses"])
            self.assertEqual(prefix + "-shard-${{ matrix.shardIndex }}", step["with"]["name"])
            self.assertIn("apps/desktop-flutter/coverage/lcov.info", step["with"]["path"])
            self.assertEqual("7", step["with"]["retention-days"])
            self.assertNotIn("continue-on-error", step)
            artifact_names.extend(step["with"]["name"].replace("${{ matrix.shardIndex }}", str(index))
                                  for index in range(4))
        self.assertEqual(8, len(set(artifact_names)))
        self.assertEqual("error", steps["Upload Windows unit test coverage"]["with"]["if-no-files-found"])
        for label in ("Package portable zip", "Smoke test packaged client", "Upload dev artifact"):
            self.assertEqual("matrix.shardIndex == 0", steps[label]["if"])
            self.assertNotIn("continue-on-error", steps[label])
        for step in self.job["steps"]:
            if step.get("uses") == "actions/upload-artifact@v4":
                self.assertTrue("${{ matrix.shardIndex }}" in step["with"]["name"]
                                or step.get("if") == "matrix.shardIndex == 0")
        for label in ("Build Windows release", "Swap in pinned Windows libmpv (full FFmpeg)"):
            self.assertNotIn("if", steps[label], "Every shard needs real native test dependencies")

    def test_matrix_contract_rejects_missing_duplicate_extra_and_cancelled_shards(self):
        for indices in (["0", "1", "2"], ["0", "1", "2", "2"], ["0", "1", "2", "3", "4"]):
            mutant = copy.deepcopy(self.job)
            mutant["strategy"]["matrix"]["shardIndex"] = indices
            with self.subTest(indices=indices), self.assertRaises(AssertionError):
                check_matrix_contract(self, mutant)
        mutant = copy.deepcopy(self.job)
        mutant["strategy"]["fail-fast"] = "true"
        with self.assertRaises(AssertionError):
            check_matrix_contract(self, mutant)

    def test_gate_contract_rejects_failure_masking_and_skipped_gate(self):
        for update in ({"if": "success()"}, {"continue-on-error": "true"}, {"needs": ["build-linux"]}):
            jobs = copy.deepcopy(self.document["jobs"])
            gate = next(job for job in jobs.values() if job.get("name") == REQUIRED_CHECK)
            gate.update(update)
            with self.subTest(update=update), self.assertRaises(AssertionError):
                check_gate_contract(self, jobs)
        jobs = copy.deepcopy(self.document["jobs"])
        gate = next(job for job in jobs.values() if job.get("name") == REQUIRED_CHECK)
        gate["steps"][0]["run"] = "exit 0"
        with self.assertRaises(AssertionError):
            check_gate_contract(self, jobs)

    def test_windows_jobs_have_no_test_skip_or_failure_masking_fields(self):
        def check_fields(value):
            if isinstance(value, dict):
                self.assertNotIn("skip", value)
                self.assertNotIn("continue-on-error", value)
                for item in value.values():
                    check_fields(item)
            elif isinstance(value, list):
                for item in value:
                    check_fields(item)
        check_fields(self.job)
        check_fields(self.document["jobs"]["windows-gate"])

    def test_four_native_shards_keep_complete_discovery_and_original_budgets(self):
        check_matrix_contract(self, self.job)


if __name__ == "__main__":
    unittest.main()
