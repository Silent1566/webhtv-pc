import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/flutter_test_diagnostics_windows.ps1"


def statements(source):
    return [line.strip() for line in source.splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def check_execution_contract(test, source):
    lines = statements(source)
    calls = [(index, line) for index, line in enumerate(lines)
             if re.match(r"&\s+flutter\s", line, re.IGNORECASE)]
    test.assertEqual(1, len(calls), "Run Flutter exactly once, without a pipeline")
    index, call = calls[0]
    test.assertRegex(call, r"^& flutter test --coverage --verbose ")
    test.assertIn('"--file-reporter=json:$eventsPath"', call)
    test.assertRegex(call, r"1> \$stdoutPath 2> \$stderrPath$")
    test.assertNotIn("|", call, "A pipeline must not obscure the native exit status")
    for flag in ("--reporter", "--concurrency", "--exclude-tags", "--ignore-timeouts"):
        test.assertNotIn(flag, source)
    test.assertIn("$PSNativeCommandUseErrorActionPreference = $false", lines[:index])
    test.assertEqual("$flutterExitCode = $LASTEXITCODE", lines[index + 1],
                     "Capture before any diagnostic/native post-processing")
    test.assertEqual("exit $flutterExitCode", lines[-1])
    test.assertEqual(["exit $flutterExitCode"],
                     [line for line in lines if re.match(r"exit\b", line, re.IGNORECASE)])
    assignments = re.findall(r"(?im)^\s*\$flutterExitCode\s*(?:[+*/-]?=|\+\+|--).*$", source)
    test.assertEqual(["$flutterExitCode = $LASTEXITCODE"],
                     [assignment.strip() for assignment in assignments])
    test.assertEqual("try {", lines[index + 2])
    test.assertIn("} catch {", lines[index + 3:-1])
    test.assertNotRegex(source, r"(?im)^\s*(?:throw|return|break|continue)\b")
    test.assertNotRegex(source, r"(?i)(?:Set-Variable|Set-Item).*flutterExitCode")
    test.assertEqual(1, len(re.findall(r"(?i)\$LASTEXITCODE\b", source)))


class FlutterTestDiagnosticsWindowsTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_text(encoding="utf-8") if SCRIPT.exists() else ""

    def test_native_exit_is_captured_immediately_and_is_the_only_exit(self):
        check_execution_contract(self, self.source)

    def test_artifacts_are_relative_to_app_working_directory(self):
        self.assertRegex(self.source, r"\[string\]\$DiagnosticsDirectory = 'ci-test-diagnostics'")
        self.assertIn("Join-Path (Get-Location).Path $DiagnosticsDirectory", self.source)
        for name in ("stdout.log", "stderr.log", "events.json", "summary.json"):
            self.assertIn("Join-Path $diagnosticsPath '" + name + "'", self.source)
        self.assertNotRegex(self.source, r"(?i)\b(?:Set-Location|Push-Location|Remove-Item|Start-Process)\b")

    def test_coverage_metadata_and_bounded_tails_follow_exit_capture(self):
        self.assertIn("$flutterExitCode = $LASTEXITCODE", self.source)
        before, after = self.source.split("$flutterExitCode = $LASTEXITCODE", 1)
        self.assertNotIn("Get-Item", before)
        self.assertIn("Get-Item -LiteralPath 'coverage/lcov.info'", after)
        for field in ("flutterExitCode", "coverageExists", "coverageBytes", "coverageLastWriteTimeUtc"):
            self.assertRegex(after, rf"(?m)^\s*{field} = ")
        self.assertIn("$coverage.Length", after)
        self.assertIn("$coverage.LastWriteTimeUtc.ToString('o')", after)
        self.assertIn("ConvertTo-Json", after)
        self.assertIn("Write-Host $summaryJson", after)
        self.assertIn("foreach ($logPath in @($stdoutPath, $stderrPath))", after)
        self.assertRegex(after, r"Get-Content -LiteralPath \$logPath -Tail 80\b")

    def test_guard_rejects_postprocessing_before_capture(self):
        self.assertTrue(self.source, "Diagnostic script has not been implemented")
        mutant = self.source.replace("$flutterExitCode = $LASTEXITCODE",
                                     "Write-Host 'post-processing'\n$flutterExitCode = $LASTEXITCODE")
        with self.assertRaises(AssertionError):
            check_execution_contract(self, mutant)

    def test_guard_rejects_masked_failure_and_changed_test_strategy(self):
        self.assertTrue(self.source, "Diagnostic script has not been implemented")
        mutants = [
            self.source.replace("exit $flutterExitCode", "exit 0"),
            self.source.replace("} catch {", "} catch {\n    $flutterExitCode = 0"),
            self.source.replace("--coverage --verbose", "--verbose"),
            self.source.replace("--coverage --verbose", "--coverage --verbose --reporter=expanded"),
        ]
        for mutant in mutants:
            with self.subTest(mutant=mutant), self.assertRaises(AssertionError):
                check_execution_contract(self, mutant)


class WindowsDiagnosticWorkflowTests(unittest.TestCase):
    def setUp(self):
        document = yaml.load(
            (ROOT / ".github/workflows/desktop-ci.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        self.steps = document["jobs"]["build-windows"]["steps"]

    def test_test_step_returns_the_diagnostic_scripts_exit_status(self):
        unit_tests = next(step for step in self.steps if step["name"] == "Unit tests")
        commands = statements(unit_tests["run"])
        self.assertEqual(
            ["& ../../scripts/flutter_test_diagnostics_windows.ps1", "exit $LASTEXITCODE"],
            commands[-2:],
        )
        self.assertNotIn("continue-on-error", unit_tests)
        self.assertEqual("30", unit_tests["timeout-minutes"])

    def test_diagnostics_upload_even_on_failure_without_changing_test_outcome(self):
        uploads = [step for step in self.steps
                   if step.get("name") == "Upload Windows unit test diagnostics"]
        self.assertEqual(1, len(uploads))
        upload = uploads[0]
        self.assertEqual("always()", upload["if"])
        self.assertEqual("actions/upload-artifact@v4", upload["uses"])
        self.assertIn("apps/desktop-flutter/ci-test-diagnostics/", upload["with"]["path"])
        self.assertIn("apps/desktop-flutter/coverage/lcov.info", upload["with"]["path"])
        self.assertEqual("7", upload["with"]["retention-days"])
        self.assertNotIn("continue-on-error", upload)
        names = [step["name"] for step in self.steps]
        self.assertLess(names.index("Unit tests"), names.index(upload["name"]))
        self.assertLess(names.index(upload["name"]), names.index("Package portable zip"))


if __name__ == "__main__":
    unittest.main()
