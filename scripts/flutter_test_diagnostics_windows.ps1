[CmdletBinding()]
param(
    [string]$DiagnosticsDirectory = 'ci-test-diagnostics',
    [ValidateRange(1, 2147483647)]
    [int]$TotalShards,
    [ValidateRange(0, 2147483647)]
    [int]$ShardIndex,
    # 加载期故障（flutter_tester 握手失败）的最多重试次数；真实用例失败永不重试。
    [ValidateRange(0, 3)]
    [int]$LoadFailureRetries = 1
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($PSBoundParameters.ContainsKey('TotalShards') -ne $PSBoundParameters.ContainsKey('ShardIndex')) {
    Write-Error 'TotalShards and ShardIndex must be supplied together.'
}
if ($PSBoundParameters.ContainsKey('TotalShards') -and $ShardIndex -ge $TotalShards) {
    Write-Error 'ShardIndex must be less than TotalShards.'
}

. (Join-Path $PSScriptRoot 'flutter_test_load_failures.ps1')

$diagnosticsPath = Join-Path (Get-Location).Path $DiagnosticsDirectory
New-Item -ItemType Directory -Force -Path $diagnosticsPath | Out-Null
$stdoutPath = Join-Path $diagnosticsPath 'stdout.log'
$stderrPath = Join-Path $diagnosticsPath 'stderr.log'
$eventsPath = Join-Path $diagnosticsPath 'events.json'
$summaryPath = Join-Path $diagnosticsPath 'summary.json'

$shardArguments = @()
if ($PSBoundParameters.ContainsKey('TotalShards')) {
    $shardArguments = @("--total-shards=$TotalShards", "--shard-index=$ShardIndex")
}

& flutter test --coverage --verbose "--file-reporter=json:$eventsPath" @shardArguments 1> $stdoutPath 2> $stderrPath
$flutterExitCode = $LASTEXITCODE
$firstRunExitCode = $flutterExitCode
$loadRetryAttempts = 0
$loadRetryFiles = @()

try {
    $reported = Get-FlutterTestFailureReport -EventsPath $eventsPath
    $loadRetryFiles = @($reported.LoadFailures)
    $realFailures = @($reported.TestFailures)
    if ($flutterExitCode -ne 0 -and $realFailures.Count -gt 0) {
        Write-Host "Real test failures present ($($realFailures.Count)); load-failure retry is disabled for this run."
        $loadRetryFiles = @()
    }
} catch {
    Write-Host "Failure classification skipped: $_"
    $loadRetryFiles = @()
}

while ($flutterExitCode -ne 0 -and $loadRetryFiles.Count -gt 0 -and $loadRetryAttempts -lt $LoadFailureRetries) {
    $loadRetryAttempts++
    Write-Host "Only load failures were reported ($($loadRetryFiles.Count) file(s)); retrying them (attempt $loadRetryAttempts/$LoadFailureRetries)."
    foreach ($file in $loadRetryFiles) { Write-Host "  retry: $file" }
    & flutter test @loadRetryFiles 1>> $stdoutPath 2>> $stderrPath
    $flutterExitCode = $LASTEXITCODE
    if ($flutterExitCode -ne 0) {
        $retryReport = Get-FlutterTestFailureReport -EventsPath $eventsPath
        $loadRetryFiles = @($retryReport.LoadFailures)
        if (@($retryReport.TestFailures).Count -gt 0) { $loadRetryFiles = @() }
    }
}

try {
    Write-Host "Flutter exit code: $flutterExitCode (first run: $firstRunExitCode, load-failure retries: $loadRetryAttempts)"
    $coverage = Get-Item -LiteralPath 'coverage/lcov.info' -ErrorAction SilentlyContinue
    $summary = [ordered]@{
        flutterExitCode = $flutterExitCode
        firstRunExitCode = $firstRunExitCode
        loadFailureRetryAttempts = $loadRetryAttempts
        loadFailureRetryFiles = @($loadRetryFiles)
        coverageExists = [bool]$coverage
        coverageBytes = if ($coverage) { $coverage.Length } else { $null }
        coverageLastWriteTimeUtc = if ($coverage) { $coverage.LastWriteTimeUtc.ToString('o') } else { $null }
    }
    $summaryJson = $summary | ConvertTo-Json
    Write-Host $summaryJson
    Set-Content -LiteralPath $summaryPath -Value $summaryJson -Encoding utf8
    foreach ($logPath in @($stdoutPath, $stderrPath)) {
        Write-Host "--- $logPath (last 80 lines) ---"
        Get-Content -LiteralPath $logPath -Tail 80 -Encoding utf8
    }
} catch {
    Write-Host "Diagnostic post-processing failed (Flutter exit code remains $flutterExitCode): $_"
}

exit $flutterExitCode
