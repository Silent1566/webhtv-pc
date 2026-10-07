# WebHTV PC Phase 4 验收脚本（TMDB 元数据增强 · Windows）
#
# 一条命令跑完 Phase 4 验收门禁（docs/phase4/README.md §3、design/05 §6）：
#   0. TMDB fixture 预检（路由可达、__stats 可用、请求捕获头可读、错误码正确）
#   1. 契约与 fixture（Python unittest）+ Schema 校验
#   2. 静态检查（dart analyze）
#   3. 单元测试（flutter test，含 phase4_tmdb_* 套件）
#   4. Windows 集成测试（-d windows，五个 tmdb_*_flow_test.dart）
#   5. 凭据脱敏校验（tools/phase4/verify_tmdb_redaction.py）
#   6. 汇总并输出 PHASE4-ACCEPT 可复查事实行
#
# 设计原则与 Phase 1/2/3 保持一致：
#   - 失败不静默：每个步骤独立捕获退出码，失败记入 $script:Failures；
#   - 原生命令 stderr 不作为失败判据（关闭 PSNativeCommandUseErrorActionPreference）；
#   - 所有事实行写入 docs/phase4/evidence/windows-acceptance.txt，可复查；
#   - 支持 -SkipIntegrationTests 快速回归。
#
# 用法：
#   pwsh -File tools/phase4/run_windows_acceptance.ps1
#   pwsh -File tools/phase4/run_windows_acceptance.ps1 -SkipIntegrationTests

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
$EvidenceDir = Join-Path $RepoRoot 'docs\phase4\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 4 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null

function Write-Step {
    param([string]$Message)
    $line = "PHASE4-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE4-ACCEPT $Message"
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

# 判定一次 `flutter test` 输出是否只是 **flutter_tools 自身的临时目录竞态**
# （与 Phase 3 同一判据：时间戳停在 00:00、用例体未执行、finalize 删目录失败）。
# 这类失败重跑一次并在证据里明确记下；其它任何失败一律不重试。
function Test-FlutterToolsTempRace {
    param([string]$Output)
    if (-not $Output) { return $false }
    if ($Output -notmatch 'PathNotFoundException: Deletion failed') { return $false }
    if ($Output -notmatch 'flutter_tools\.') { return $false }
    if ($Output -notmatch 'did not complete') { return $false }
    return $true
}

# ------------------------------------------------------------------ 前置

if (-not (Get-Command puro -ErrorAction SilentlyContinue)) {
    throw '未找到 puro，无法解析 Flutter/Dart 工具链。'
}

# 选择 Python 解释器。
#
# 契约测试（tests/test_contracts.py）与 schema 校验（scripts/validate_contracts.py）
# 依赖 `jsonschema`。本机 `py` 启动器的默认版本可能没装该模块（实测：`py` → 3.14
# 无 jsonschema，`py -3.13` 有 4.26.0），此时门禁会以 ImportError 失败——那是
# 环境漂移而不是代码缺陷，但一键验收脚本的可复现性不应依赖启动器默认值。
# 因此这里主动探测「能 import jsonschema」的解释器并钉住它；探测全部失败时
# 退回原行为（裸 `py`），由门禁自己报错，不静默跳过。
function Resolve-PythonWithJsonschema {
    $attempts = @(
        @{ Exe = 'py'; Args = @('-3.13') },
        @{ Exe = 'py'; Args = @('-3.12') },
        @{ Exe = 'py'; Args = @('-3.11') },
        @{ Exe = 'py'; Args = @('-3.10') },
        @{ Exe = 'py'; Args = @('-3') },
        @{ Exe = 'python'; Args = @() },
        @{ Exe = 'python3'; Args = @() }
    )
    foreach ($attempt in $attempts) {
        if (-not (Get-Command $attempt.Exe -ErrorAction SilentlyContinue)) { continue }
        $probe = & $attempt.Exe @($attempt.Args + @('-c', 'import sys, jsonschema; print(sys.executable)')) 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe) {
            Write-Fact "python selected=$($attempt.Exe) $($attempt.Args -join ' ') exe=$($probe.Trim())"
            return @{ Command = $attempt.Exe; Args = $attempt.Args }
        }
    }
    Write-Fact 'python fallback=py -3（jsonschema 探测失败，由门禁自己报错）'
    return @{ Command = 'py'; Args = @('-3') }
}

$pythonSpec = Resolve-PythonWithJsonschema
$pythonCommand = $pythonSpec.Command
$pythonArgs = $pythonSpec.Args

function Invoke-Python {
    param([string[]]$Arguments)
    & $pythonCommand @($pythonArgs + $Arguments)
}

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
    $stdout = Join-Path $RepoRoot '.local\tmp\webhtv-fixture-phase4.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $stdout) | Out-Null
    # 显式覆盖测试进程可见的 fixture 基址，避免外层残留的旧端口导致门禁随机失败
    # （详见 Phase 3 脚本 Start-FixtureServer 的注释）。
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"
    $script:FixtureProcess = Start-Process -FilePath $pythonCommand `
        -ArgumentList @($pythonArgs + @('-m', 'tools.fixture_server.server', '--port', "$FixturePort")) `
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
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"

    # 0) TMDB fixture 预检：路由可达、__stats 可用、请求捕获头可读、错误码正确。
    Invoke-Checked 'tmdb-fixture-preflight' {
        Invoke-Python @(
            (Join-Path $RepoRoot 'tools\phase4\check_tmdb_fixture.py'),
            '--base', "http://127.0.0.1:$FixturePort"
        )
    }

    # 1) Python 契约测试 + Schema 校验（含 4 个新增 TMDB 用例）。
    Invoke-Checked 'python-contract-tests' {
        Push-Location $RepoRoot
        try {
            Invoke-Python @('-m', 'unittest', 'tests.test_contracts', '-v')
        } finally {
            Pop-Location
        }
    }
    Invoke-Checked 'schema-validation' {
        Invoke-Python @((Join-Path $RepoRoot 'scripts\validate_contracts.py'))
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

    # 3) 单元测试（含 phase4_tmdb_* 门禁套件；全部自带进程内 fake HTTP，无网络）。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter test
        } finally {
            Pop-Location
        }
    }

    # 3.5) phase4 套件清单核对：设计文档 §3 列出的套件必须都存在且被执行。
    Invoke-Checked 'phase4-suite-presence' {
        $required = @(
            'test/phase4_tmdb_title_test.dart',
            'test/phase4_tmdb_match_policy_test.dart',
            'test/phase4_tmdb_site_policy_test.dart',
            'test/phase4_tmdb_cache_test.dart',
            'test/phase4_tmdb_season_resolver_test.dart',
            'test/phase4_tmdb_available_seasons_test.dart',
            'test/phase4_tmdb_segment_test.dart',
            'test/phase4_tmdb_progress_test.dart',
            'test/phase4_tmdb_config_test.dart',
            'test/phase4_tmdb_image_selector_test.dart',
            'test/phase4_tmdb_episode_metadata_test.dart',
            'test/phase4_tmdb_service_test.dart',
            'test/phase4_tmdb_storage_test.dart',
            'test/phase4_tmdb_ui_test.dart',
            'test/phase4_tmdb_playback_test.dart',
            'test/phase4_tmdb_state_test.dart'
        )
        $missing = @()
        foreach ($relative in $required) {
            if (-not (Test-Path (Join-Path $AppDir $relative))) { $missing += $relative }
        }
        if ($missing.Count -gt 0) {
            throw "缺少 phase4 套件：$($missing -join ', ')"
        }
        Write-Fact "phase4-suite-presence suites=$($required.Count) missing=0"
    }

    # 4) Windows 集成测试（真实窗口 + 真实 HTTP fixture + 真实播放器）。
    if (-not $SkipIntegrationTests) {
        function Invoke-FlutterIntegrationSuite {
            param([string]$Name, [string]$File)
            $output = & puro -e $PuroEnvironment -p . flutter test $File -d windows 2>&1
            $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
            $output | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { return $true }
            if (Test-FlutterToolsTempRace ($output -join "`n")) {
                Write-Fact "$Name retry reason=flutter-tools-temp-race"
                $output = & puro -e $PuroEnvironment -p . flutter test $File -d windows 2>&1
                $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
                $output | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -eq 0) {
                    Write-Fact "$Name retry-ok"
                    return $true
                }
            }
            return $false
        }

        Invoke-Checked 'windows-integration-tests' {
            Push-Location $AppDir
            try {
                $global:LASTEXITCODE = 0
                $suites = @(
                    # 详情集成（design/05 §5.1）：真实窗口 + 真实 HTTP + 季度切换。
                    'integration_test/tmdb_detail_flow_test.dart',
                    # 播放集成（§5.2）：真实播放器 + 季度身份透传 + 续播 + 换源续播。
                    'integration_test/tmdb_playback_flow_test.dart',
                    # 手动匹配集成（§5.3）：持久化 + 仅选季度 + 清除绑定。
                    'integration_test/tmdb_manual_match_flow_test.dart',
                    # 失败隔离集成（§5.4）：401 不阻塞播放 + 熔断计数不增。
                    'integration_test/tmdb_failure_isolation_flow_test.dart',
                    # 纯 TMDB 详情页（§5.5）：卡片不可播 + 跳搜索页。
                    'integration_test/tmdb_tmdb_only_detail_flow_test.dart'
                )
                foreach ($suite in $suites) {
                    if (-not (Invoke-FlutterIntegrationSuite -Name $suite -File $suite)) {
                        $global:LASTEXITCODE = 1
                        return
                    }
                }
                $global:LASTEXITCODE = 0
            } finally {
                Pop-Location
            }
        }
    } else {
        Write-Step 'windows-integration-tests (跳过)'
        Write-Fact 'windows-integration-tests skipped'
    }

    # 5) 凭据脱敏校验（design/05 §7.3）：日志与诊断导出不得出现凭据原文。
    Invoke-Checked 'tmdb-redaction' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase4\verify_tmdb_redaction.py'))
    }

    # 5.5) 恢复 Debug 产物为「可运行的应用入口」。
    #
    # 与 Phase 3 同一缺陷：`flutter test <file> -d windows` 会把**测试**内核快照写进
    # 应用输出目录，双击 exe 会启动集成测试入口（进程活着但首帧永不到达）。
    # 无条件重建，保证交付目录里的 exe 可直接双击运行。
    Invoke-Checked 'restore-debug-artifacts' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter build windows --debug
        } finally {
            Pop-Location
        }
    }

    # 5.6) 产物可运行性门禁：正向断言 Debug 产物确实是应用入口。
    Invoke-Checked 'debug-artifact-runnable' {
        $kernel = Join-Path $AppDir 'build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin'
        if (-not (Test-Path $kernel)) {
            throw "kernel_blob 缺失：$kernel"
        }
        $bytes = [System.IO.File]::ReadAllBytes($kernel)
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $hasMainEntry = $text.Contains('lib/main.dart') -or $text.Contains('lib\main.dart')
        $testMarkers = ([regex]::Matches($text, 'integration_test')).Count
        Write-Fact "debug-artifact-runnable kernel=$kernel main-entry=$hasMainEntry integration-test-markers=$testMarkers"
        if (-not $hasMainEntry -or $testMarkers -gt 0) {
            throw "Debug 产物入口不是 lib/main.dart（main-entry=$hasMainEntry integration-test-markers=$testMarkers，疑似被集成测试覆盖）"
        }
    }

    # 6) 汇总。
    Write-Step 'summary'
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE4-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        Write-Host "PHASE4-ACCEPT 全部门禁通过，详见 $LogFile"
        exit 0
    } else {
        $summary = "PHASE4-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
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
