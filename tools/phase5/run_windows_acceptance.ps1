# WebHTV PC Phase 5 验收脚本（安卓桥接 + 历史/设置同步 · Windows）
#
# 一条命令跑完 Phase 5 验收门禁（docs/phase5/README.md §3、design/03 §6）：
#   G1  安卓 fixture 预检（路由可达 / Host 派生 / 8 种故障注入）
#   G2  Python 契约测试（tests/test_contracts.py 的 8 个新增用例）
#   G3  Schema 校验
#   G4  静态检查（dart analyze）
#   G5  单元测试（flutter test，含 phase5_* 套件）
#   G6  套件存在性（phase5_* 清单核对）
#   G7  Windows 集成测试（3 个 phase5_*_flow_test.dart）
#   G8  反向验证（6 项必须"按预期失败"且还原后工作区干净）
#   G9  脱敏（TMDB 凭据 + 桥接设备指纹/片名）
#   G10 发布包符号（安卓接入入口的 AOT 可达性）
#   G11 产物可运行（Debug 入口必须是 lib/main.dart）
#
# 设计原则与 Phase 1–4 保持一致：
#   - 失败不静默：每个步骤独立捕获退出码，失败记入 $script:Failures；
#   - 原生命令 stderr 不作为失败判据（关闭 PSNativeCommandUseErrorActionPreference）；
#   - 所有事实行写入 docs/phase5/evidence/windows-acceptance.txt，可复查；
#   - 支持 -SkipIntegrationTests 快速回归。
#
# 用法：
#   pwsh -File tools/phase5/run_windows_acceptance.ps1
#   pwsh -File tools/phase5/run_windows_acceptance.ps1 -SkipIntegrationTests
#   pwsh -File tools/phase5/run_windows_acceptance.ps1 -BuildReleaseForSymbols
#   # 可选：把真机只读探测摘要写入证据（不作为门禁，design/03 §7.1）
#   pwsh -File tools/phase5/run_windows_acceptance.ps1 -ProbeRealDevice 192.168.50.3:9978

param(
    [string]$PuroEnvironment = 'webhtv',
    [switch]$SkipIntegrationTests,
    [switch]$BuildReleaseForSymbols,
    [int]$FixturePort = 18080,
    [string]$ProbeRealDevice = ''
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
$EvidenceDir = Join-Path $RepoRoot 'docs\phase5\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 5 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null
$script:FixtureWasRunning = $false

function Write-Step {
    param([string]$Message)
    $line = "PHASE5-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE5-ACCEPT $Message"
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
# （与 Phase 3/4 同一判据）。这类失败重跑一次并在证据里明确记下；其它一律不重试。
function Test-FlutterToolsTempRace {
    param([string]$Output)
    if (-not $Output) { return $false }
    if ($Output -notmatch 'PathNotFoundException: Deletion failed') { return $false }
    if ($Output -notmatch 'flutter_tools\.') { return $false }
    if ($Output -notmatch 'did not complete') { return $false }
    return $true
}

function Test-FixtureServer {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $FixturePort)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Start-FixtureServer {
    if (Test-FixtureServer) {
        $script:FixtureWasRunning = $true
        Write-Fact "fixture-server already-running port=$FixturePort (由本脚本外启动，结束时不会关闭)"
        return
    }
    $stdout = Join-Path $RepoRoot '.local\tmp\webhtv-fixture-phase5.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $stdout) | Out-Null
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
    if ($script:FixtureWasRunning) {
        Write-Fact 'fixture-server kept-running reason=started-externally'
        return
    }
    if ($null -ne $script:FixtureProcess -and -not $script:FixtureProcess.HasExited) {
        Stop-Process -Id $script:FixtureProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Fact "fixture-server stopped pid=$($script:FixtureProcess.Id)"
    }
}

# ------------------------------------------------------------------ 前置

if (-not (Get-Command puro -ErrorAction SilentlyContinue)) {
    throw '未找到 puro，无法解析 Flutter/Dart 工具链。'
}

# 选择带 jsonschema 的 Python 解释器（与 Phase 4 同一理由与实现）。
function Resolve-PythonWithJsonschema {
    $attempts = @(
        @{ Exe = 'py'; Args = @('-3.13') },
        @{ Exe = 'py'; Args = @('-3.12') },
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

# ------------------------------------------------------------------ 主流程

try {
    Start-FixtureServer
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"

    # G1 安卓 fixture 预检：路由可达 / Host 派生 / 8 种故障注入逐一可触发。
    Invoke-Checked 'android-fixture-preflight' {
        Invoke-Python @(
            (Join-Path $RepoRoot 'tools\phase5\check_android_fixture.py'),
            '--base', "http://127.0.0.1:$FixturePort"
        )
    }

    # G2 Python 契约测试（含安卓 fixture 的 8 个新增用例）。
    Invoke-Checked 'python-contract-tests' {
        Push-Location $RepoRoot
        try {
            Invoke-Python @('-m', 'unittest', 'tests.test_contracts', '-v')
        } finally {
            Pop-Location
        }
    }

    # G3 Schema 校验。
    Invoke-Checked 'schema-validation' {
        Invoke-Python @((Join-Path $RepoRoot 'scripts\validate_contracts.py'))
    }

    # G4 静态检查。
    Invoke-Checked 'dart-analyze' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . dart analyze
        } finally {
            Pop-Location
        }
    }

    # G5 单元测试（phase5_* 套件全部自带进程内 fake，无真实网络/窗口）。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter test
        } finally {
            Pop-Location
        }
    }

    # G6 套件存在性：设计文档列出的套件必须都存在。
    Invoke-Checked 'phase5-suite-presence' {
        $required = @(
            'test/phase5_android_bridge_test.dart',
            'test/phase5_android_sync_test.dart',
            'test/phase5_android_bridge_service_test.dart',
            'test/phase5_sync_storage_test.dart',
            'test/phase5_sync_server_test.dart',
            'test/phase5_sync_client_test.dart',
            'test/phase5_sync_ui_test.dart'
        )
        $missing = @()
        foreach ($relative in $required) {
            if (-not (Test-Path (Join-Path $AppDir $relative))) { $missing += $relative }
        }
        if ($missing.Count -gt 0) {
            throw "缺少 phase5 套件：$($missing -join ', ')"
        }
        # 纯 PowerShell 检查没有原生命令：必须显式清零 `$LASTEXITCODE`，
        # 否则会沿用上一步（flutter test）的退出码，把上一步的失败重复记到本步骤。
        $global:LASTEXITCODE = 0
        Write-Fact "phase5-suite-presence suites=$($required.Count) missing=0"
    }

    # G7 Windows 集成测试（真实窗口 + 真实 HTTP + 真实 SQLite）。
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
                    # 桥接集成（design/03 §5.1）：接入 → 导入（不切换配置）→
                    # 首页请求的 Host 一致性 → 两类故障注入。
                    'integration_test/phase5_bridge_flow_test.dart',
                    # 同步接收集成（§5.2）：开启服务端 → 真实 HTTP 推送 →
                    # 历史页可见 → 幂等 / 旧不覆盖新 → 端口释放。
                    'integration_test/phase5_sync_flow_test.dart',
                    # 推送集成（§5.3）：形态断言（mode/type/cid=0/不带 settings）+
                    # 403 的安卓侧开关指引。
                    'integration_test/phase5_sync_push_flow_test.dart'
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

    # G8 反向验证（design/03 §4.3）：6 项必须"按预期失败"，还原后工作区干净。
    Invoke-Checked 'android-reverse-checks' {
        Invoke-Python @(
            (Join-Path $RepoRoot 'tools\phase5\verify_reverse_checks.py'),
            '--puro-env', $PuroEnvironment
        )
    }

    # G9 脱敏：TMDB 凭据（沿用 Phase 4 口径）+ 桥接设备指纹/片名/配置 JSON。
    Invoke-Checked 'tmdb-redaction' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase4\verify_tmdb_redaction.py'))
    }
    Invoke-Checked 'bridge-redaction' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase5\verify_bridge_redaction.py'))
    }

    # G10 发布包符号与入口可达性（安卓接入入口的 AOT 可达性）。
    #
    # ⚠️ 与 Phase 4 同一教训：`flutter test` 是 JIT/debug 不做 tree-shaking，
    #    集成用例还会直接写 settings.json 绕过 UI 入口。只有 release AOT 产物
    #    能暴露「入口被条件挡住 → 整页被剔除」。
    # 默认只校验已存在的产物；`-BuildReleaseForSymbols` 才主动构建。
    Invoke-Checked 'release-symbols' {
        $appSo = Join-Path $AppDir 'build\windows\x64\runner\Release\data\app.so'
        if ($BuildReleaseForSymbols) {
            Push-Location $AppDir
            try {
                & puro -e $PuroEnvironment -p . flutter build windows --release
                if ($LASTEXITCODE -ne 0) {
                    # 已知临时文件锁：产物可能已更新，重跑一次即可。
                    Write-Fact 'release-build retry=1（MSB3073 临时文件锁）'
                    & puro -e $PuroEnvironment -p . flutter build windows --release
                }
            } finally {
                Pop-Location
            }
        }
        if (-not (Test-Path $appSo)) {
            Write-Fact 'release-symbols skipped reason=no-release-artifact（加 -BuildReleaseForSymbols 或打包后单独跑 verify_release_symbols.py）'
            $global:LASTEXITCODE = 0
            return
        }
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase5\verify_release_symbols.py'))
    }

    # 可选：真机只读探测留痕（不作为门禁，design/03 §7.1）。
    if ($ProbeRealDevice -ne '') {
        Invoke-Checked 'real-device-probe' {
            Invoke-Python @(
                (Join-Path $RepoRoot 'tools\phase5\probe_real_device.py'),
                '--device', $ProbeRealDevice,
                '--out', (Join-Path $EvidenceDir 'device-probe.txt')
            )
        }
    }

    # 恢复 Debug 产物为「可运行的应用入口」。
    #
    # 与 Phase 3/4 同一缺陷：`flutter test <file> -d windows` 会把**测试**内核快照
    # 写进应用输出目录，双击 exe 会启动集成测试入口。无条件重建。
    Invoke-Checked 'restore-debug-artifacts' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter build windows --debug
        } finally {
            Pop-Location
        }
    }

    # G11 产物可运行性：Debug 产物入口必须是 lib/main.dart。
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
            throw "Debug 产物入口不是 lib/main.dart（main-entry=$hasMainEntry integration-test-markers=$testMarkers）"
        }
    }

    # 汇总。
    Write-Step 'summary'
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE5-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        Write-Host "PHASE5-ACCEPT 全部门禁通过，详见 $LogFile"
        exit 0
    } else {
        $summary = "PHASE5-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
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
