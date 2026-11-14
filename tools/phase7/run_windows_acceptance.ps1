# WebHTV PC Phase 7 验收脚本（安卓实时同步 + 保活心跳 + 续播修复 · Windows）
#
# 一条命令跑完 Phase 7 验收门禁（docs/phase7/README.md §3、design/04 §6）：
#   G1  安卓 fixture 预检（5 路由 + 9 故障注入 + TCP 模式）
#   G2  Python 契约测试
#   G3  Schema 校验
#   G4  静态检查（dart analyze）
#   G5  单元测试（flutter test）
#   G6  套件存在性（phase7_* 清单核对）
#   G7  Windows 集成测试（phase7_*_flow_test.dart，逐套件单独跑）
#   G8  反向验证（8 项必须"按预期失败"且还原后工作区干净）
#   G9  脱敏（Phase 5 桥接 + Phase 7 实时同步）
#   G10 发布包符号（实时同步/手动操作的 AOT 可达性）
#   G11 设计文档一致性（章节号 / 引用 / 契约快照 / 套件清单）
#   G12 定时器无泄漏（引擎套件逐个用例断言活动定时器=0）
#
# 设计原则与 Phase 1–6 保持一致：
#   - 失败不静默：每个步骤独立捕获退出码，失败记入 $script:Failures；
#   - 原生命令 stderr 不作为失败判据（关闭 PSNativeCommandUseErrorActionPreference）；
#   - 所有事实行写入 docs/phase7/evidence/windows-acceptance.txt，可复查；
#   - 支持 -SkipIntegrationTests 快速回归。
#
# 用法：
#   pwsh -File tools/phase7/run_windows_acceptance.ps1
#   pwsh -File tools/phase7/run_windows_acceptance.ps1 -SkipIntegrationTests
#   pwsh -File tools/phase7/run_windows_acceptance.ps1 -BuildReleaseForSymbols
#   # 可选：把真机只读探测摘要写入证据（不作为门禁）
#   pwsh -File tools/phase7/run_windows_acceptance.ps1 -ProbeRealDevice 192.168.50.3:5559

param(
    [string]$PuroEnvironment = 'webhtv',
    [switch]$SkipIntegrationTests,
    [switch]$BuildReleaseForSymbols,
    [int]$FixturePort = 18080,
    [int]$TcpPort = 18081,
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
$EvidenceDir = Join-Path $RepoRoot 'docs\phase7\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 7 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null
$script:FixtureWasRunning = $false

function Write-Step {
    param([string]$Message)
    $line = "PHASE7-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE7-ACCEPT $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Invoke-Checked {
    param([string]$Name, [scriptblock]$Action)
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

# 判定一次 `flutter test` 输出是否只是 flutter_tools 自身的临时目录竞态
# （与 Phase 3–6 同一判据）。这类失败重跑一次并在证据里明确记下；其它一律不重试。
function Test-FlutterToolsTempRace {
    param([string]$Output)
    if (-not $Output) { return $false }
    if ($Output -notmatch 'PathNotFoundException: Deletion failed') { return $false }
    if ($Output -notmatch 'flutter_tools\.') { return $false }
    if ($Output -notmatch 'did not complete') { return $false }
    return $true
}

function Invoke-Python {
    param([string[]]$Arguments)
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3 @Arguments
    } else {
        & python @Arguments
    }
}

function Test-PortListening {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(300)
        $connected = $ok -and $client.Connected
        $client.Close()
        return $connected
    } catch {
        return $false
    }
}

function Start-FixtureServer {
    if (Test-PortListening -Port $FixturePort) {
        Write-Fact "fixture-server already-running port=$FixturePort"
        $script:FixtureWasRunning = $true
        return
    }
    $script:FixtureProcess = Start-Process -FilePath 'py' -ArgumentList @(
        '-3', (Join-Path $RepoRoot 'tools\fixture_server\server.py'),
        '--port', $FixturePort,
        '--tcp-mode', 'tcp-accept-silent',
        '--tcp-port', $TcpPort
    ) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-PortListening -Port $FixturePort) {
            Write-Fact "fixture-server started port=$FixturePort tcp-port=$TcpPort"
            return
        }
    }
    throw "fixture 服务启动超时（port=$FixturePort）"
}

function Stop-FixtureServer {
    # 只关闭**本脚本启动的**进程：复用外部已运行的服务时不得动它。
    if ($script:FixtureProcess -and -not $script:FixtureWasRunning) {
        try {
            Stop-Process -Id $script:FixtureProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Fact "fixture-server stopped pid=$($script:FixtureProcess.Id)"
        } catch {
            Write-Fact "fixture-server stop-failed error=$($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------ 主流程

try {
    Start-FixtureServer
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"
    # 保活 L3 需要 TCP 故障注入端口（`--tcp-mode tcp-accept-silent`）。
    $env:WEBHTV_FIXTURE_TCP_PORT = "$TcpPort"

    # G1 安卓 fixture 预检：5 个新路由 + 9 种故障注入 + TCP 模式。
    Invoke-Checked 'android-fixture-preflight' {
        Invoke-Python @(
            (Join-Path $RepoRoot 'tools\phase7\check_android_fixture.py'),
            '--base', "http://127.0.0.1:$FixturePort",
            '--tcp', "127.0.0.1:$TcpPort"
        )
    }

    # G2 Python 契约测试。
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

    # G5 单元测试（phase7_* 套件全部自带进程内 fake，无真实网络/窗口）。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter test
        } finally {
            Pop-Location
        }
    }

    # G6 套件存在性：设计文档列出的套件必须都存在。
    Invoke-Checked 'phase7-suite-presence' {
        $required = @(
            'test/phase7_realtime_core_test.dart',
            'test/phase7_keepalive_test.dart',
            'test/phase7_resume_gate_test.dart',
            'test/phase7_player_advance_test.dart',
            'test/phase7_settings_mapping_test.dart',
            'test/phase7_android_read_client_test.dart',
            'test/phase7_pull_endpoint_test.dart',
            'test/phase7_identity_resolve_test.dart',
            'test/phase7_identity_persistence_test.dart',
            'test/phase7_realtime_engine_test.dart',
            'test/phase7_realtime_state_test.dart',
            'test/phase7_sync_ui_test.dart',
            'integration_test/phase7_resume_flow_test.dart',
            'integration_test/phase7_realtime_flow_test.dart',
            'integration_test/phase7_keepalive_flow_test.dart'
        )
        $missing = @()
        foreach ($relative in $required) {
            if (-not (Test-Path (Join-Path $AppDir $relative))) { $missing += $relative }
        }
        if ($missing.Count -gt 0) {
            throw "缺少 phase7 套件：$($missing -join ', ')"
        }
        # 纯 PowerShell 检查没有原生命令：必须显式清零 $LASTEXITCODE，
        # 否则会沿用上一步（flutter test）的退出码，把失败重复记到本步骤。
        $global:LASTEXITCODE = 0
        Write-Fact "phase7-suite-presence suites=$($required.Count) missing=0"
    }

    # G7 Windows 集成测试（真实窗口 + 真实 HTTP + 真实 SQLite）。
    #
    # 逐套件单独跑：`flutter test integration_test -d windows` 一次跑多个会互相
    # 争用窗口与端口，而且一个套件挂住就没有任何证据。
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
                    # 续播集成（design/03 §5）：提前 EOF 不跳集 + 恢复续播。
                    'integration_test/phase7_resume_flow_test.dart',
                    # 实时同步端到端（design/04 §3.1）：真实 HTTP 增量 + 幂等 + 403。
                    'integration_test/phase7_realtime_flow_test.dart',
                    # 保活三态端到端（design/02 §4）：真实 socket 区分
                    # 「服务未运行」与「进程被冻结」。
                    'integration_test/phase7_keepalive_flow_test.dart'
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

    # G8 反向验证（design/04 §5）：8 项必须"按预期失败"，还原后工作区干净。
    Invoke-Checked 'realtime-reverse-checks' {
        Invoke-Python @(
            (Join-Path $RepoRoot 'tools\phase7\verify_reverse_checks.py'),
            '--puro-env', $PuroEnvironment
        )
    }

    # G9 脱敏：Phase 5 桥接口径 + Phase 7 实时同步口径。
    Invoke-Checked 'bridge-redaction' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase5\verify_bridge_redaction.py'))
    }
    Invoke-Checked 'realtime-redaction' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase7\verify_realtime_redaction.py'))
    }

    # G10 发布包符号与入口可达性（实时同步/手动操作的 AOT 可达性）。
    #
    # ⚠️ 与 Phase 4/5 同一教训：`flutter test` 是 JIT/debug 不做 tree-shaking，
    #    集成用例还会直接写 settings.json 绕过 UI 入口。只有 release AOT 产物
    #    能暴露「入口被条件挡住 → 整块被剔除」。
    #
    # 默认只校验已存在的产物（尊重「webhtv 项目不打正式包」的约定）；
    # 产物比源码旧时脚本会报 STALE-SKIP 而不是 FAIL——那种情况下
    # 无法区分「AOT 剔除」与「没重新构建」。
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
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase7\verify_release_symbols.py'))
    }

    # G11 设计文档一致性（章节号连续 / 引用可解析 / 契约快照与源码一致）。
    Invoke-Checked 'design-docs' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase7\verify_design_docs.py'))
    }

    # G12 定时器无泄漏：引擎套件每个用例结束时活动定时器必须为 0。
    #
    # 为什么要单独一步：Dart 的 `Timer` 未取消时，`flutter test` 只在
    # `testWidgets` 里报 "A Timer is still pending"，纯 `test()` 不会。
    # 引擎套件是纯 `test()`，所以必须靠套件内的显式断言（tearDown 里查
    # `activeTimerCount`），这一步确保那个套件真的跑了。
    Invoke-Checked 'timer-leak-gate' {
        Push-Location $AppDir
        try {
            $output = & puro -e $PuroEnvironment -p . flutter test test/phase7_realtime_engine_test.dart 2>&1
            $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
            $output | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) { return }
            # 断言套件里的 G12 检查确实存在（否则"通过"只说明它没写这条断言）。
            $suite = Get-Content -Raw (Join-Path $AppDir 'test/phase7_realtime_engine_test.dart')
            if ($suite -notmatch 'activeTimerCount, 0') {
                throw 'phase7_realtime_engine_test.dart 缺少 activeTimerCount==0 断言（G12）'
            }
            Write-Fact 'timer-leak-gate suite-assertion=present'
            $global:LASTEXITCODE = 0
        } finally {
            Pop-Location
        }
    }

    # 可选：真机只读探测留痕（不作为门禁）。
    if ($ProbeRealDevice -ne '') {
        Write-Step "real-device-probe target=$ProbeRealDevice"
        Write-Fact "real-device-probe skipped reason=manual（Phase 7 暂无自动探测脚本，请用 design/02 §6 的手工脚本）"
    }

    # 恢复 Debug 产物为「可运行的应用入口」。
    #
    # 与 Phase 3–6 同一缺陷：`flutter test <file> -d windows` 会把**测试**内核快照
    # 写进应用输出目录，双击 exe 会启动集成测试入口。无条件重建。
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'restore-debug-artifacts' {
            Push-Location $AppDir
            try {
                & puro -e $PuroEnvironment -p . flutter build windows --debug
            } finally {
                Pop-Location
            }
        }

        Invoke-Checked 'debug-artifact-runnable' {
            $kernel = Join-Path $AppDir 'build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin'
            if (-not (Test-Path $kernel)) {
                throw "kernel_blob 缺失：$kernel"
            }
            $bytes = [System.IO.File]::ReadAllBytes($kernel)
            $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
            $hasMainEntry = $text.Contains('lib/main.dart') -or $text.Contains('lib\main.dart')
            # 污染判据必须用**测试绑定**这个真符号，不能用裸 `integration_test`
            # 文本或测试文件名。
            #
            # 为什么（两次实测误报）：
            # 1. `lib/ui/library_pages.dart` 的文档注释里引用了
            #    `integration_test/phase5_sync_flow_test.dart`（说明「片名只渲染
            #    一次」这条契约由哪个测试锁定）——文档注释会进 kernel_blob；
            # 2. 连具名的 `phase5_sync_flow_test.dart` 也同样在注释里出现。
            #
            # 真正的污染（测试内核被当成应用入口）特征是：应用入口
            # `lib/main.dart` **缺失**，且测试**绑定**符号存在。
            # 实测干净产物：`IntegrationTestWidgetsFlutterBinding` count=0、
            # `lib/main.dart` count=1。
            $testMarkers = ([regex]::Matches($text, 'IntegrationTestWidgetsFlutterBinding')).Count
            Write-Fact "debug-artifact-runnable kernel=$kernel main-entry=$hasMainEntry test-binding-markers=$testMarkers"
            if (-not $hasMainEntry -or $testMarkers -gt 0) {
                throw "Debug 产物入口不是 lib/main.dart（main-entry=$hasMainEntry test-binding-markers=$testMarkers）"
            }
        }
    }

    # 汇总。
    Write-Step 'summary'
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE7-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        Write-Host "PHASE7-ACCEPT 全部门禁通过，详见 $LogFile"
        exit 0
    } else {
        $summary = "PHASE7-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
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
