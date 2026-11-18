[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')][string]$Mode = 'release',
    [string]$FlutterBat = '',
    [int]$StallSeconds = 120,
    [string[]]$FlutterArgs = @()
)
$ErrorActionPreference = 'Stop'

# Runs the Windows build with a heartbeat and, when output stops, records the
# process tree that is actually holding it up. The build has silent phases
# (cmake configure, native-asset hooks, MSBuild custom commands), so a hang
# otherwise leaves no evidence about which step is stuck.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $RepoRoot 'apps/desktop-flutter'
$LogDir = Join-Path $RepoRoot '.local/build-watch'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if (-not $FlutterBat) {
    if ($env:FLUTTER_ROOT) { $FlutterBat = Join-Path $env:FLUTTER_ROOT 'bin/flutter.bat' }
    else {
        $found = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $FlutterBat = $found.Source }
    }
}
if (-not $FlutterBat -or -not (Test-Path -LiteralPath $FlutterBat)) { throw 'flutter.bat not found; pass -FlutterBat <path>' }

& pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/prepare_windows_native_deps.ps1') -Offline

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "build-$stamp.log"
$stdoutFile = Join-Path $LogDir "build-$stamp.stdout"
$stderrFile = Join-Path $LogDir "build-$stamp.stderr"

$arguments = @('build', 'windows', "--$Mode") + $FlutterArgs
$started = Get-Date
Write-Host "flutter $($arguments -join ' ')  (log: $logFile)"
$process = Start-Process -FilePath $FlutterBat -ArgumentList $arguments -WorkingDirectory $AppDir -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

$offsets = @{}
$offsets[$stdoutFile] = [long]0
$offsets[$stderrFile] = [long]0
$pending = @{}
$pending[$stdoutFile] = ''
$pending[$stderrFile] = ''
$targets = @($stdoutFile, $stderrFile)
$phase = 'starting'
$lastOutput = Get-Date
$dumped = $false

function Read-NewText([string]$Path, [long]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $stream.Seek($Offset, [IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-ProcessCpu([int]$Id) {
    try { return (Get-Process -Id $Id -ErrorAction Stop).CPU } catch { return $null }
}

function Write-StallSnapshot([string]$Reason, [int]$Idle) {
    $snapshot = Join-Path $LogDir ("stall-$stamp-" + $Idle + 's.txt')
    try {
    $all = Get-CimInstance Win32_Process
    $depth = @{}
    $depth[[int]$process.Id] = 0
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            $childId = [int]$p.ProcessId
            if (-not $depth.ContainsKey($childId) -and $depth.ContainsKey([int]$p.ParentProcessId)) {
                $depth[$childId] = $depth[[int]$p.ParentProcessId] + 1
                $grew = $true
            }
        }
    }
    $candidates = $all | Where-Object {
        $depth.ContainsKey([int]$_.ProcessId) -or $_.Name -match '^(MSBuild|cl|link|cmake|ninja|dart|gen_snapshot|nuget|git|curl)\.exe$'
    }
    $cpuBefore = @{}
    foreach ($c in $candidates) { $cpuBefore[[int]$c.ProcessId] = Get-ProcessCpu ([int]$c.ProcessId) }
    Start-Sleep -Seconds 3
    $lines = @()
    $lines += "reason       : $Reason"
    $lines += "flutter pid  : $($process.Id)"
    $lines += "idle seconds : $Idle"
    $lines += "phase hint   : $phase"
    $lines += "captured at  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += 'pid    ppid   depth cpu_delta_s rss_mb name              command line'
    $lines += '-----  -----  ----- ----------- ------ ----------------- ------------------------------'
    foreach ($c in ($candidates | Sort-Object { $depth[[int]$_.ProcessId] })) {
        $childId = [int]$c.ProcessId
        $cpuNow = Get-ProcessCpu $childId
        $before = $cpuBefore[$childId]
        $delta = if ($null -ne $cpuNow -and $null -ne $before) { [math]::Round($cpuNow - $before, 1) } else { '?' }
        $level = if ($depth.ContainsKey($childId)) { $depth[$childId] } else { '-' }
        $rss = [math]::Round($c.WorkingSetSize / 1MB, 0)
        $cmd = if ($c.CommandLine) { $c.CommandLine.Trim() } else { '' }
        if ($cmd.Length -gt 150) { $cmd = $cmd.Substring(0, 150) }
        $lines += ('{0,-5}  {1,-5}  {2,-5} {3,-11} {4,-6} {5,-17} {6}' -f $childId, $c.ParentProcessId, $level, $delta, $rss, $c.Name, $cmd)
    }
    $lines | Set-Content -LiteralPath $snapshot -Encoding utf8
    Write-Host ''
    Write-Host "STALL ${Idle}s -> $snapshot"
    Write-Host '  deepest processes in the stuck tree:'
    $candidates | Sort-Object { if ($depth.ContainsKey([int]$_.ProcessId)) { $depth[[int]$_.ProcessId] } else { 99 } } | Select-Object -Last 3 | ForEach-Object {
        $cmd = if ($_.CommandLine) { $_.CommandLine.Substring(0, [Math]::Min(110, $_.CommandLine.Length)) } else { '' }
        Write-Host "    $($_.ProcessId) [$($_.Name)] $cmd"
    }
    Write-Host ''
    } catch {
        Write-Host "WARN could not write stall snapshot: $($_.Exception.Message)"
    }
}

while (-not $process.HasExited) {
    $wrote = $false
    foreach ($target in $targets) {
        $chunk = Read-NewText $target $offsets[$target]
        if (-not $chunk) { continue }
        $offsets[$target] += [Text.Encoding]::UTF8.GetByteCount($chunk)
        $buffer = $pending[$target] + ($chunk -replace "`r", '')
        $parts = $buffer -split "`n"
        $pending[$target] = $parts[$parts.Count - 1]
        foreach ($line in $parts) {
            if (-not $line.Trim()) { continue }
            $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            $rendered = "[+$seconds" + "s] $line"
            Write-Host $rendered
            Add-Content -LiteralPath $logFile -Value $rendered -Encoding utf8
            if ($line -match 'Building Windows application') { $phase = 'cmake configure / native asset hooks' }
            if ($line -match 'Configuring done|Build files have been written') { $phase = 'MSBuild (compile + custom commands)' }
            if ($line -match 'Building Custom Rule|Compiling|link\.exe') { $phase = 'MSVC compile' }
            $wrote = $true
        }
    }
    if ($wrote) { $lastOutput = Get-Date; $dumped = $false }
    $idle = [int](((Get-Date) - $lastOutput).TotalSeconds)
    if (-not $dumped -and $idle -ge $StallSeconds) {
        Write-StallSnapshot $phase $idle
        $dumped = $true
    } elseif (-not $wrote -and $idle -gt 0 -and $idle % 20 -eq 0) {
        Write-Host "[+$([math]::Round(((Get-Date) - $started).TotalSeconds, 0))s] waiting ${idle}s - $phase"
    }
    Start-Sleep -Milliseconds 400
}

foreach ($target in $targets) {
    $chunk = Read-NewText $target $offsets[$target]
    if ($chunk) { Add-Content -LiteralPath $logFile -Value $chunk -Encoding utf8 }
}
$total = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
Write-Host "flutter exit=$($process.ExitCode) elapsed=${total}s log=$logFile"
exit $process.ExitCode
