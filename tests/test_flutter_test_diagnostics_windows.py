import json
import os
import re
import shutil
import subprocess
import tempfile
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

    def test_optional_shards_use_only_sdk_flags_and_validate_before_execution(self):
        self.assertIn("[ValidateRange(1, 2147483647)]", self.source)
        self.assertIn("[ValidateRange(0, 2147483647)]", self.source)
        self.assertIn("$PSBoundParameters.ContainsKey('TotalShards') -ne $PSBoundParameters.ContainsKey('ShardIndex')",
                      self.source)
        self.assertIn("$ShardIndex -ge $TotalShards", self.source)
        self.assertIn('$shardArguments = @()', self.source)
        self.assertIn('$shardArguments = @("--total-shards=$TotalShards", "--shard-index=$ShardIndex")',
                      self.source)
        self.assertLess(self.source.index("$ShardIndex -ge $TotalShards"), self.source.index("& flutter test"))
        self.assertNotRegex(self.source, r"(?i)--(?:name|plain-name|exclude|tags|skip)")

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


@unittest.skipUnless(os.name == "nt" and shutil.which("pwsh"), "Windows PowerShell interface test")
class WindowsDiagnosticScriptInterfaceTests(unittest.TestCase):
    def run_script(self, arguments, native_exit=0, break_postprocessing=False):
        with tempfile.TemporaryDirectory() as directory:
            command = """
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
function flutter {
    ConvertTo-Json -InputObject @($args) -Compress | Set-Content -LiteralPath 'arguments.json'
    New-Item -ItemType Directory -Path 'coverage' -Force | Out-Null
    Set-Content -LiteralPath 'coverage/lcov.info' -Value 'TN:fixture'
    $reporter = $args | Where-Object { $_ -like '--file-reporter=json:*' }
    Set-Content -LiteralPath $reporter.Substring('--file-reporter=json:'.Length) -Value '{"type":"done"}'
    Write-Output 'fixture stdout'
    [Console]::Error.WriteLine('fixture stderr')
    if (BREAK_POSTPROCESSING) {
        New-Item -ItemType Directory -Path 'ci-test-diagnostics/summary.json' | Out-Null
    }
    & $env:ComSpec /c exit NATIVE_EXIT
}
& 'SCRIPT' ARGUMENTS
exit $LASTEXITCODE
""".replace("NATIVE_EXIT", str(native_exit)).replace(
                "BREAK_POSTPROCESSING", "$true" if break_postprocessing else "$false"
            ).replace("SCRIPT", str(SCRIPT).replace("'", "''")).replace(
                "ARGUMENTS", " ".join(arguments)
            )
            result = subprocess.run(
                [shutil.which("pwsh"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
                cwd=directory, capture_output=True, text=True, encoding="utf-8", timeout=30,
            )
            root = Path(directory)
            native_arguments = root / "arguments.json"
            summary = root / "ci-test-diagnostics/summary.json"
            artifacts = {name: (root / "ci-test-diagnostics" / name).is_file()
                         for name in ("stdout.log", "stderr.log", "events.json")}
            return (result, json.loads(native_arguments.read_text(encoding="utf-8-sig"))
                    if native_arguments.exists() else None,
                    json.loads(summary.read_text(encoding="utf-8-sig")) if summary.is_file() else None,
                    artifacts)

    def test_native_failure_survives_diagnostics_and_postprocessing_failure(self):
        for arguments in ([], ["-TotalShards", "4", "-ShardIndex", "3"]):
            for break_postprocessing in (False, True):
                with self.subTest(arguments=arguments, break_postprocessing=break_postprocessing):
                    result, actual, summary, artifacts = self.run_script(
                        arguments, native_exit=7, break_postprocessing=break_postprocessing,
                    )
                    self.assertEqual(7, result.returncode, result.stderr)
                    self.assertIsNotNone(actual)
                    self.assertTrue(all(artifacts.values()))
                    if break_postprocessing:
                        self.assertIsNone(summary)
                        self.assertIn("Diagnostic post-processing failed", result.stdout)
                    else:
                        self.assertEqual(7, summary["flutterExitCode"])
                        self.assertTrue(summary["coverageExists"])

    def test_invalid_shard_parameters_fail_before_native_execution(self):
        invalid = [
            ["-TotalShards", "4"], ["-ShardIndex", "0"],
            ["-TotalShards", "0", "-ShardIndex", "0"],
            ["-TotalShards", "-1", "-ShardIndex", "0"],
            ["-TotalShards", "4", "-ShardIndex", "-1"],
            ["-TotalShards", "4", "-ShardIndex", "4"],
            ["-TotalShards", "4", "-ShardIndex", "5"],
            ["-TotalShards", "2147483648", "-ShardIndex", "0"],
        ]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result, actual, summary, artifacts = self.run_script(arguments)
                self.assertNotEqual(0, result.returncode)
                self.assertIsNone(actual, "Invalid shards must not run any tests")
                self.assertIsNone(summary)
                self.assertFalse(any(artifacts.values()))

    def test_native_shards_are_optional_paired_and_cover_all_four_indices(self):
        for arguments, expected in [([], []), *[
            (["-TotalShards", "4", "-ShardIndex", str(index)],
             ["--total-shards=4", f"--shard-index={index}"]) for index in range(4)
        ]]:
            with self.subTest(arguments=arguments):
                result, actual, summary, artifacts = self.run_script(arguments)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(["test", "--coverage", "--verbose"], actual[:3])
                self.assertRegex(actual[3], r"^--file-reporter=json:.*events\.json$")
                self.assertEqual(expected, actual[4:], "Only SDK shards may narrow discovery")
                self.assertEqual(0, summary["flutterExitCode"])
                self.assertTrue(summary["coverageExists"])
                self.assertTrue(all(artifacts.values()))


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
        # 加载期偶发故障（flutter_tester 握手失败）由独立脚本兜底重试；诊断脚本本身',
        # 仍然只调用一次 flutter、原样带出退出码，重试不进入它的契约。
        self.assertEqual(
            ["& ../../scripts/flutter_test_diagnostics_windows.ps1 -TotalShards 4 -ShardIndex ${{ matrix.shardIndex }}",
             "if ($LASTEXITCODE -ne 0) { & ../../scripts/flutter_test_retry_load_failures.ps1 }",
             "exit $LASTEXITCODE"],
            commands[-3:],
        )
        self.assertNotIn("continue-on-error", unit_tests)
        # 预算要跟实测走：2026-11-24 的 beta 绿跑里 Windows 全量单测 29.3 分钟，
        # 30 分钟上限只剩 0.7 分钟余量，新增任何用例都会直接超时。这条断言仍保持
        # 精确值（改动必须同时改这里），只是把值调到按实测留足余量的 45 分钟。
        self.assertEqual("45", unit_tests["timeout-minutes"])

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


class WindowsReleaseWorkflowTests(unittest.TestCase):
    def test_full_suite_keeps_measured_runtime_headroom(self):
        document = yaml.load(
            (ROOT / ".github/workflows/desktop-release.yml").read_text(encoding="utf-8"),
            Loader=yaml.BaseLoader,
        )
        steps = document["jobs"]["build-windows"]["steps"]
        unit_tests = next(step for step in steps if step["name"] == "Unit tests")
        self.assertGreaterEqual(int(unit_tests["timeout-minutes"]), 45)


if __name__ == "__main__":
    unittest.main()
