# WebHTV PC Phase 2 验收脚本（MVP-B · Windows）
#
# 一条命令跑完 Phase 2 的验收门禁（docs/phase2/README.md §3 与 §3.1）：
#   0. 媒体 fixture 预检（确认 Header 门禁生效）
#   1. 契约与 fixture 测试（Python）+ manifest/消息 Schema 校验
#   2. 静态检查（dart analyze）
#   3. 单元测试（flutter test，含 8 个 phase2_* 门禁套件）
#   4. Windows 集成测试（真实窗口 + 真实播放 + 进度恢复 UI 闭环，-d windows）
#   5. 汇总并输出 PHASE2-ACCEPT 可复查事实行
#
# 设计原则与 Phase 1 保持一致：
#   - 失败不静默：每个步骤独立捕获退出码，失败记入 $script:Failures；
#   - 原生命令 stderr 不作为失败判据（PowerShell 7.3+ 会把原生 stderr 提升为
#     终止性错误，必须关闭该行为，仅以退出码判定）；
#   - 所有事实行写入 docs/phase2/evidence/windows-acceptance.txt，可复查。
#
# 用法：
#   pwsh -File tools/phase2/run_windows_acceptance.ps1
#   pwsh -File tools/phase2/run_windows_acceptance.ps1 -SkipIntegrationTests
#
# 说明：Phase 2 门禁以「单元测试 + 集成测试」为可复现入口（§3.1 注），
# 不执行 Release 打包与首帧采样（那些属于 Phase 1 验收脚本的范围）。

[CmdletBinding()]
param(
    [string]$PuroEnvironment = 'webhtv',
    [switch]$SkipIntegrationTests,
    [int]$FixturePort = 18080
)

$ErrorActionPreference = 'Stop'
# 中文输出必须可读。
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$AppDir = Join-Path $RepoRoot 'apps\desktop-flutter'
$EvidenceDir = Join-Path $RepoRoot 'docs\phase2\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'
$mediaUrl = "http://127.0.0.1:$FixturePort/media/sample.m3u8"
$mediaReferer = "http://127.0.0.1:$FixturePort/"
$mediaUserAgent = 'WebHTV-PC/0.1 (Windows)'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 2 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null

function Write-Step {
    param([string]$Message)
    $line = "PHASE2-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE2-ACCEPT $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Invoke-Checked {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Step $Name
    $started = Get-Date
    $previousErrorAction = $ErrorActionPreference
    $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & $Action 2>&1
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
        $elapsed = ((Get-Date) - $started).TotalMilliseconds
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            Write-Fact "$Name FAILED elapsed=$([int]$elapsed)ms exit=$exitCode"
            $script:Failures += $Name
            return $false
        }
        Write-Fact "$Name ok elapsed=$([int]$elapsed)ms"
        return $true
    } catch {
        $elapsed = ((Get-Date) - $started).TotalMilliseconds
        Write-Fact "$Name FAILED elapsed=$([int]$elapsed)ms error=$($_.Exception.Message)"
        Add-Content -Path $LogFile -Value $_.ScriptStackTrace -Encoding utf8
        $script:Failures += $Name
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorAction
        $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    }
}

# ------------------------------------------------------------------ 前置

if (-not (Get-Command puro -ErrorAction SilentlyContinue)) {
    throw '未找到 puro，无法解析 Flutter/Dart 工具链。'
}
$python = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }

function Test-FixtureServer {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$FixturePort/health" -TimeoutSec 3 -UseBasicParsing
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Start-FixtureServer {
    if (Test-FixtureServer) {
        Write-Fact "fixture-server already-running port=$FixturePort"
        return
    }
    $stdout = Join-Path $Env:TEMP "webhtv-fixture-phase2-$FixturePort.log"
    $script:FixtureProcess = Start-Process -FilePath $python `
        -ArgumentList '-m', 'tools.fixture_server.server', '--port', $FixturePort `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err"
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-FixtureServer) {
            Write-Fact "fixture-server started pid=$($script:FixtureProcess.Id) port=$FixturePort"
            return
        }
        Start-Sleep -Milliseconds 300
    }
    throw "fixture 服务未能在 20 秒内启动（端口 $FixturePort）"
}

function Stop-FixtureServer {
    if ($null -ne $script:FixtureProcess -and -not $script:FixtureProcess.HasExited) {
        Stop-Process -Id $script:FixtureProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Fact "fixture-server stopped pid=$($script:FixtureProcess.Id)"
    }
}

# ------------------------------------------------------------------ 主流程

try {
    Start-FixtureServer

    # 0) 媒体 fixture 预检：Header 门禁必须生效（带 Header 200，不带 403）。
    Invoke-Checked 'media-fixture-preflight' {
        $withHeaders = (& curl.exe -s -o NUL -w '%{http_code}' `
            -H "Referer: $mediaReferer" -H "User-Agent: $mediaUserAgent" $mediaUrl)
        $noHeaders = (& curl.exe -s -o NUL -w '%{http_code}' $mediaUrl)
        $log = "preflight with-header=$withHeaders no-header=$noHeaders"
        if ($withHeaders -ne '200') { throw "媒体带 Header 应 200，实际 $withHeaders" }
        if ($noHeaders -ne '403') { throw "媒体不带 Header 应 403，实际 $noHeaders" }
        Write-Host $log
    }

    # 1) Python 契约测试 + Schema 校验。
    Invoke-Checked 'python-contract-tests' {
        Push-Location $RepoRoot
        try {
            & $python -m unittest tests.test_contracts -v
        } finally {
            Pop-Location
        }
    }
    Invoke-Checked 'schema-validation' {
        & $python (Join-Path $RepoRoot 'scripts\validate_contracts.py')
    }

    # 2) 静态检查。
    Invoke-Checked 'dart-analyze' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . dart analyze
        } finally {
            Pop-Location
        }
    }

    # 3) 单元测试（含 8 个 phase2_* 门禁套件；自带进程内 fixture 服务，可独立运行）。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter test
        } finally {
            Pop-Location
        }
    }

    # 4) Windows 集成测试（真实窗口 + 真实播放 + 进度恢复 UI 闭环）。
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'windows-integration-tests' {
            Push-Location $AppDir
            try {
                & puro -e $PuroEnvironment -p . flutter test integration_test/mvp_a_flow_test.dart -d windows
            } finally {
                Pop-Location
            }
        }
    } else {
        Write-Step 'windows-integration-tests (跳过)'
        Write-Fact 'windows-integration-tests skipped'
    }

    # 5) 汇总。
    Write-Step 'summary'
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE2-ACCEPT result=PASS gates=all"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        Write-Host "PHASE2-ACCEPT 全部门禁通过，详见 $LogFile"
        exit 0
    } else {
        $summary = "PHASE2-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        exit 1
    }
} catch {
    Write-Fact "fatal error=$($_.Exception.Message)"
    Add-Content -Path $LogFile -Value $_.ScriptStackTrace -Encoding utf8
    exit 2
} finally {
    Stop-FixtureServer
}