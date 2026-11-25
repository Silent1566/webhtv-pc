[CmdletBinding()]
param(
    [string]$DiagnosticsDirectory = 'ci-test-diagnostics',
    [ValidateRange(1, 2147483647)]
    [int]$TotalShards,
    [ValidateRange(0, 2147483647)]
    [int]$ShardIndex
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($PSBoundParameters.ContainsKey('TotalShards') -ne $PSBoundParameters.ContainsKey('ShardIndex')) {
    Write-Error 'TotalShards and ShardIndex must be supplied together.'
}
if ($PSBoundParameters.ContainsKey('TotalShards') -and $ShardIndex -ge $TotalShards) {
    Write-Error 'ShardIndex must be less than TotalShards.'
}

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

try {
    Write-Host "Flutter exit code: $flutterExitCode"
    $coverage = Get-Item -LiteralPath 'coverage/lcov.info' -ErrorAction SilentlyContinue
    $summary = [ordered]@{
        flutterExitCode = $flutterExitCode
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
