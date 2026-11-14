# WebHTV PC · Windows 发布包启动烟测
#
# 复用应用自带的自动化探针（`--screenshot-ready-file`）：主界面可交互后，
# 应用会写入一行 `WebHTV PC <version> (<flavor>) platform=... arch=... player=...`
# 的 `StartupInfo.oneLine`。本脚本断言版本号、平台与播放器引擎，然后强制结束
# 进程树，避免在 CI 里留下 GUI 进程。
#
# 用法：
#   pwsh -File scripts/smoke_windows.ps1 `
#     -ExePath <解压后的目录>\webhtv_pc.exe -ExpectedVersion 0.1.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,

    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "烟测失败：找不到可执行文件 $ExePath"
}
$exePath = (Resolve-Path -LiteralPath $ExePath).Path
$exeDir = Split-Path -Parent $exePath

foreach ($relative in @(
        'sidecars/spider-host-python/host.py',
        'sidecars/spider-host-js/host.js',
        'sidecars/spider-host-jvm/host.jar'
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $exeDir $relative) -PathType Leaf)) {
        throw "烟测失败：发行包缺少 sidecar 宿主 $relative（应位于 exe 同级）。"
    }
}

# Low 完整性标签会让非提权进程写不进 %APPDATA%，现场表现是「数据库打不开、历史与
# 设置丢失」，而 icacls 看权限一切正常——本地构建产物常继承该标签。烟测前先归位，
# 让本地构建也自动兜住。对目录本身设标签需要 WRITE_OWNER，权限不足时只告警不阻断。
# 现场记录：docs/troubleshooting/readonly-storage-low-integrity.md
$integrityOutput = icacls $exeDir /setintegritylevel "(OI)(CI)Medium" /T /C 2>&1
$integrityFailed = 0
foreach ($line in $integrityOutput) {
    if ("$line" -match 'Failed processing\s+(\d+)\s+files') { $integrityFailed += [int]$Matches[1] }
}
if ($LASTEXITCODE -ne 0 -or $integrityFailed -gt 0) {
    Write-Warning "完整性标签归位未完全成功（失败 $integrityFailed 项，退出码 $LASTEXITCODE），烟测继续"
}

$tempRoot = [IO.Path]::GetTempPath()
$token = [Guid]::NewGuid().ToString('N')
$readyFile = Join-Path $tempRoot "webhtv-ready-$token.txt"
$traceFile = Join-Path $tempRoot "webhtv-trace-$token.txt"
$stdoutFile = Join-Path $tempRoot "webhtv-stdout-$token.txt"
$stderrFile = Join-Path $tempRoot "webhtv-stderr-$token.txt"

# Start-Process 把数组元素按空格拼成命令行，含空格的路径必须内嵌引号。
$arguments = @(
    "--screenshot-ready-file=`"$readyFile`"",
    "--startup-trace=`"$traceFile`""
)

Write-Host "启动烟测：$exePath"
$process = Start-Process -FilePath $exePath `
    -WorkingDirectory $exeDir `
    -ArgumentList $arguments `
    -PassThru `
    -WindowStyle Normal `
    -RedirectStandardOutput $stdoutFile `
    -RedirectStandardError $stderrFile

$failure = $null
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $readyFile -PathType Leaf) { break }
        if ($process.HasExited) {
            throw "应用在写出 ready 文件前退出（exit=$($process.ExitCode)）。"
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
        throw "等待 ${TimeoutSeconds}s 仍未写出 ready 文件（主界面未进入可交互状态）。"
    }

    $content = Get-Content -LiteralPath $readyFile -Raw -Encoding utf8
    $oneLine = ($content -split "`r?`n" | Where-Object { $_ -match '^WebHTV PC ' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($oneLine)) {
        throw "ready 文件缺少启动信息行，实际内容：`n$content"
    }

    $expectedPrefix = "WebHTV PC $ExpectedVersion "
    if (-not $oneLine.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
        throw "版本不一致：期望以 '$expectedPrefix' 开头，实际 '$oneLine'。"
    }
    if ($oneLine -notmatch 'platform=windows') {
        throw "平台信息不符：$oneLine"
    }
    if ($oneLine -notmatch 'player=media-kit') {
        throw "播放器引擎信息不符：$oneLine"
    }

    Write-Host "烟测通过：$oneLine"
} catch {
    $failure = $_
    throw
} finally {
    if ($process -and -not $process.HasExited) {
        & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
    }

    if ($failure) {
        Write-Host '--- 诊断信息 ---'
        $logDir = Join-Path $env:LOCALAPPDATA 'webhtv-pc\logs'
        $latestLog = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestLog) {
            Write-Host "日志：$($latestLog.FullName)"
            Get-Content -LiteralPath $latestLog.FullName -Tail 80 -Encoding utf8 -ErrorAction SilentlyContinue
        } else {
            Write-Host "日志目录没有 .log：$logDir"
        }
        if (Test-Path -LiteralPath $traceFile) {
            Write-Host '--- startup-trace ---'
            Get-Content -LiteralPath $traceFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stdoutFile) {
            Write-Host '--- stdout ---'
            Get-Content -LiteralPath $stdoutFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrFile) {
            Write-Host '--- stderr ---'
            Get-Content -LiteralPath $stderrFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }

    foreach ($path in @($readyFile, $traceFile, $stdoutFile, $stderrFile)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
