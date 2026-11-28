# CI 兜底：Windows runner 上偶发 flutter_tester 握手失败，整个测试文件「没跑起来」
# （events.json 里表现为 `loading <file>` 伪用例 result=error）。这类故障与被测代码
# 无关，重跑通常即过；但真实用例失败绝不能靠重试掩盖。
#
# 为什么独立成脚本：scripts/flutter_test_diagnostics_windows.ps1 的契约是「只调用一次
# flutter、原样带出退出码」（tests/test_flutter_test_diagnostics_windows.py 锁死），
# 重试只能放在它之外。
[CmdletBinding()]
param(
    [string]$DiagnosticsDirectory = 'ci-test-diagnostics',
    [ValidateRange(1, 3)]
    [int]$MaxAttempts = 1,
    # 只认这一类加载期故障；编译错误同样会让文件跑不起来，不能被当成偶发问题重试。
    [string]$HarnessFlakeMarker = 'Unable to connect to flutter_tester process'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'flutter_test_load_failures.ps1')

$diagnosticsPath = Join-Path (Get-Location).Path $DiagnosticsDirectory
$eventsPath = Join-Path $diagnosticsPath 'events.json'
$stdoutPath = Join-Path $diagnosticsPath 'stdout.log'
$stderrPath = Join-Path $diagnosticsPath 'stderr.log'

if (-not (Test-Path -LiteralPath $eventsPath)) {
    Write-Host 'Load-failure retry skipped: no events.json to classify.'
    exit 1
}

$report = Get-FlutterTestFailureReport -EventsPath $eventsPath
$realFailures = @($report.TestFailures)
$loadFailures = @($report.LoadFailures)
if ($realFailures.Count -gt 0) {
    Write-Host "Load-failure retry skipped: $($realFailures.Count) real test failure(s) must not be retried."
    exit 1
}
if ($loadFailures.Count -eq 0) {
    Write-Host 'Load-failure retry skipped: no test file failed to load.'
    exit 1
}
if (-not (Select-String -LiteralPath $stdoutPath -SimpleMatch -Quiet -Pattern $HarnessFlakeMarker)) {
    Write-Host 'Load-failure retry skipped: the load failure is not the known harness flake.'
    exit 1
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "Retrying $($loadFailures.Count) test file(s) that never started (attempt $attempt/$MaxAttempts)."
    foreach ($file in $loadFailures) { Write-Host "  retry: $file" }
    & flutter test @loadFailures 1>> $stdoutPath 2>> $stderrPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Load-failure retry passed; the shard is treated as successful.'
        exit 0
    }
}

Write-Host 'Load-failure retry did not pass.'
exit 1
