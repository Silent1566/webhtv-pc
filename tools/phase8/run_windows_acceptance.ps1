# WebHTV PC Phase 8 验收脚本（播放器浮层改造 · Windows）
#
# 门禁（docs/phase8/design/05 §6）与步骤的对应关系：
#   G1  静态检查（dart analyze）          → 步骤 dart-analyze
#   G2  单元测试（flutter test）          → 步骤 flutter-unit-tests
#   G3  套件存在性                        → 步骤 phase8-suite-presence
#   G4  Windows 集成测试（逐套件单独跑）   → 步骤 windows-integration-tests
#   G5  反向验证（10 项）                 → 步骤 reverse-checks
#   G6  设计文档一致性                    → 步骤 design-docs
#   G7  几何不变式专项                    → **含在 G4 里**（phase8_overlay_flow_test）
#   G8  截图证据（13 张与清单逐字节一致）  → 步骤 screenshot-evidence
#   G9  无阴影/无 elevation               → 步骤 flat-field
#   G10 字号未改                          → 步骤 metric-neutral
#   G11 既有测试回归                      → 步骤 player-integration-regression
#   G12 定时器无泄漏                      → 步骤 timer-leak-gate
#
# G7 没有独立步骤，因为它是 G4 的一个子集；
# 这里显式写明，避免「12 个门禁只有 10 个步骤」看起来像漏了。
#
# 用法：
#   pwsh -File tools/phase8/run_windows_acceptance.ps1
#   pwsh -File tools/phase8/run_windows_acceptance.ps1 -SkipIntegrationTests

param(
    [string]$PuroEnvironment = 'webhtv',
    [switch]$SkipIntegrationTests,
    [int]$FixturePort = 18080
)

$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$AppDir = Join-Path $RepoRoot 'apps\desktop-flutter'
$EvidenceDir = Join-Path $RepoRoot 'docs\phase8\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

# `media_kit` 会在 %TEMP% 下创建 `com.alexmercerind.media_kit.NativeReferenceHolder.<pid>`。
# 本机 %TEMP% 指向 F:\temp，那里有数百个历史残留文件，偶发被其它进程占用，
# 导致 `flutter test -d windows` 在加载阶段就报
#   Cannot create file, path = '\?\F:\temp\com.alexmercerind.media_kit.NativeReferenceHolder.908'
#   (OS Error: 拒绝访问。, errno = 5)
# 把 TEMP/TMP 指到仓库内的临时目录即可绕开（实测有效）。
$script:TempDir = Join-Path $RepoRoot '.superpowers\sdd\01-player-overlay\_tmp14'
New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
$env:TEMP = $script:TempDir
$env:TMP = $script:TempDir

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 8 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null
$script:FixtureWasRunning = $false

function Write-Step {
    param([string]$Message)
    $line = "PHASE8-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE8-ACCEPT $Message"
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
        '--port', $FixturePort
    ) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-PortListening -Port $FixturePort) {
            Write-Fact "fixture-server started port=$FixturePort"
            return
        }
    }
    throw "fixture 服务启动超时（port=$FixturePort）"
}

function Stop-FixtureServer {
    if ($script:FixtureProcess -and -not $script:FixtureWasRunning) {
        try {
            Stop-Process -Id $script:FixtureProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Fact "fixture-server stopped pid=$($script:FixtureProcess.Id)"
        } catch {
            Write-Fact "fixture-server stop-failed error=$($_.Exception.Message)"
        }
    }
}

try {
    Start-FixtureServer
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"

    # G1
    Invoke-Checked 'dart-analyze' {
        Push-Location $AppDir
        try { & puro -e $PuroEnvironment -p . dart analyze } finally { Pop-Location }
    }

    # G2 单元测试。
    #
    # **注意**：`flutter test` 默认只跑 `test/`，**不含** `integration_test/`。
    # 所以 G2 并不能代表「既有套件全绿」——挂载 PlayerPage 的既有集成套件
    # 由 G11（player-integration-regression）单独跑。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try { & puro -e $PuroEnvironment -p . flutter test } finally { Pop-Location }
    }

    # G3
    Invoke-Checked 'phase8-suite-presence' {
        $required = @(
            'test/phase8_osd_config_test.dart',
            'test/phase8_player_buttons_test.dart',
            'test/phase8_osd_persistence_test.dart',
            'test/phase8_app_state_config_test.dart',
            'test/phase8_osd_diagnostics_test.dart',
            'test/phase8_osd_layer_test.dart',
            'test/phase8_overlay_layout_test.dart',
            'test/phase8_context_menu_test.dart',
            'test/phase8_button_config_page_test.dart',
            'test/phase8_settings_entries_test.dart',
            'test/phase8_player_page_overlay_test.dart',
            'integration_test/phase8_overlay_flow_test.dart',
            'integration_test/phase8_visual_flow_test.dart'
        )
        $missing = @()
        foreach ($relative in $required) {
            if (-not (Test-Path (Join-Path $AppDir $relative))) { $missing += $relative }
        }
        if ($missing.Count -gt 0) {
            throw "缺少 phase8 套件：$($missing -join ', ')"
        }
        $global:LASTEXITCODE = 0
        Write-Fact "phase8-suite-presence suites=$($required.Count) missing=0"
    }

    # G4（含 G7 几何不变式——phase8_overlay_flow_test 的 V1/V2）
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'windows-integration-tests' {
            Push-Location $AppDir
            try {
                $global:LASTEXITCODE = 0
                $suites = @(
                    'integration_test/phase8_overlay_flow_test.dart',
                    'integration_test/phase8_visual_flow_test.dart'
                )
                foreach ($suite in $suites) {
                    $output = & puro -e $PuroEnvironment -p . flutter test $suite -d windows 2>&1
                    $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
                    $output | ForEach-Object { Write-Host $_ }
                    if ($LASTEXITCODE -ne 0) {
                        $global:LASTEXITCODE = 1
                        return
                    }
                }
                $global:LASTEXITCODE = 0
            } finally { Pop-Location }
        }
    } else {
        Write-Step 'windows-integration-tests (跳过)'
        Write-Fact 'windows-integration-tests skipped'
    }

    # G11 既有测试回归：挂载 PlayerPage 的既有集成套件。
    #
    # **为什么必须单列**：`flutter test`（G2）默认只跑 `test/`，不跑
    # `integration_test/`。原稿把 G11 写成「含在 G2 里」，于是 12 个挂载
    # 播放器页的既有套件**从来没被跑过**。代价是真实的：Phase 8 引入了两个
    # 会让这些套件红的改动，全部漏到最终审查才发现——
    #   1. 屏显时钟每秒 setState → 带时长的 `pumpAndSettle` 永不 settle
    #      （实测 `subtitle_flow_test.dart:148` 在 10:09 超时）；
    #   2. 控制浮层 3 秒自动隐藏 + IgnorePointer → 第二次点击静默打空。
    #
    # 只收录**必须绿**的套件。两个已知红的没有进来，原因写在
    # `docs/phase8/design/05` §6 的 G11 说明里：
    #   - `mvp_a_flow_test.dart`：基线 `ec79422` 上同样 6 通过 / 2 失败
    #     （连真实内网 192.168.50.2:9978 的 SocketException 被记到最后一条用例，
    #     以及 525 行找不到 `fixture` 文本），是环境问题，不是回归；
    #   - `ui_redesign_visual_flow_test.dart`：它的产出是
    #     `.impeccable/review/*.png`，跑一次就改写工作区里的已提交图片，
    #     不适合放在门禁里（它是证据采集，不是回归网）。
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'player-integration-regression' {
            Push-Location $AppDir
            try {
                $global:LASTEXITCODE = 0
                $playerSuites = @(
                    'integration_test/subtitle_flow_test.dart',
                    'integration_test/danmaku_flow_test.dart',
                    'integration_test/phase7_resume_flow_test.dart'
                )
                foreach ($suite in $playerSuites) {
                    $output = & puro -e $PuroEnvironment -p . flutter test $suite -d windows 2>&1
                    $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
                    $output | ForEach-Object { Write-Host $_ }
                    if ($LASTEXITCODE -ne 0) {
                        $global:LASTEXITCODE = 1
                        return
                    }
                }
                $global:LASTEXITCODE = 0
                Write-Fact "player-integration-regression suites=$($playerSuites.Count) green=all"
            } finally { Pop-Location }
        }
    } else {
        Write-Step 'player-integration-regression (跳过)'
        Write-Fact 'player-integration-regression skipped'
    }

    # G5
    Invoke-Checked 'reverse-checks' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_reverse_checks.py'))
    }

    # G6
    Invoke-Checked 'design-docs' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_design_docs.py'))
    }

    # G9
    Invoke-Checked 'flat-field' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_flat_field.py'))
    }

    # G10
    Invoke-Checked 'metric-neutral' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_metric_neutral.py'))
    }

    # G8 截图证据：13 张截图存在、非空，且与清单**逐字节一致**。
    #
    # **判据为什么长这样**（Task 14 实测换来的，两轮）：
    # 1. 原判据是「菜单截图与关闭态截图不同字节」。它是**假绿**——
    #    两个状态之间至少有两处像素必然变化：屏显时钟每秒跳动、
    #    视频在播放。实测 r2x1 档位在**菜单根本没打开**的情况下
    #    两张截图仍差 5 字节（`menuBytes=363046 closedBytes=363041`），
    #    断言照样通过。已删除。
    # 2. 换成「菜单必须是 harness 拍到的那个 `RepaintBoundary` 的后代」
    #    （在 `phase8_visual_flow_test.dart` 里，不依赖像素）。它恰好能
    #    区分「页内 Stack 层」与「`Overlay` 浮层」两种实现——也就是
    #    `design/04` §3 这个决策本身。
    # 3. 但截图本身还必须是**可复核**的：同一份代码两次跑出不同字节的
    #    PNG，就无法判断差异来自代码改动还是走时/滚动条。实测踩到两次：
    #    屏显右上角实时时钟（差异包围盒约 34×10 像素）、菜单滚到底后
    #    滚动条淡出（`jumpTo` 挂 300ms Timer，`pumpAndSettle` 立刻返回，
    #    把半透明滚动条拍进图里）。修好后连续两次跑 13/13 逐字节相同。
    #    本步骤用 `verify_screenshots.py` + `manifest.txt` 把这件事
    #    变成机器检查。
    Invoke-Checked 'screenshot-evidence' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_screenshots.py'))
    }

    # G12 定时器无泄漏。
    #
    # **判据为什么长这样**（R108 + R111，两次实测换来的）：
    # 1. 「定时器泄漏」由框架自己兜底——每个 `testWidgets` 结束时
    #    `flutter_test/src/binding.dart:2543` 会断言 `!timersPending`，
    #    套件全绿即已覆盖泄漏；
    # 2. 框架**抓不到**「该停时没停」（空转）：`_PlayerPageState.dispose()`
    #    会 cancel `_osdTimer`，所以空转的 ticker 不会留下待处理定时器。
    #    空转必须用观测缝断言；
    # 3. 观测缝是**两层**的：套件里调 `osdTickerRunning(tester)`
    #    （`test/support/player_page_harness.dart` 的包装），包装里调
    #    `debugOsdTickerRunning`（`lib/ui/player_page.dart` 的
    #    `@visibleForTesting` 函数）。**两层都要查**——只查套件会漏掉
    #    「包装被改成返回常量」，只查包装会漏掉「套件根本没调它」。
    #    实测踩到：本门禁原先只查套件里的 `debugOsdTickerRunning`，
    #    而套件用的是包装名，于是**正确实现反而门禁红**（R111）。
    # 4. **绝不能改查 `transientCallbackCount`**：加载态常挂
    #    `LoadingBlock` 的 `CircularProgressIndicator`，该计数恒 ≥1
    #    （实测推进到 25 秒仍为 1），断言永远为真——那是个装饰性门禁。
    Invoke-Checked 'timer-leak-gate' {
        Push-Location $AppDir
        try {
            $output = & puro -e $PuroEnvironment -p . flutter test test/phase8_player_page_overlay_test.dart 2>&1
            $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
            $output | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) { return }
            $suite = Get-Content -Raw (Join-Path $AppDir 'test/phase8_player_page_overlay_test.dart')
            $harness = Get-Content -Raw (Join-Path $AppDir 'test/support/player_page_harness.dart')
            if ($suite -notmatch 'osdTickerRunning') {
                throw 'phase8_player_page_overlay_test.dart 没有断言屏显刷新循环（G12）'
            }
            if ($harness -notmatch 'debugOsdTickerRunning') {
                throw 'player_page_harness.dart 的 osdTickerRunning 没有走到 debugOsdTickerRunning 观测缝（G12）'
            }
            # 查 `transientCallbackCount` 时必须**先剥掉注释行**：
            # 套件里有一条注释专门解释「为什么不能用它」，那是文档不是用法。
            # 只按裸串匹配会把正确实现判红（实测踩到）。
            foreach ($pair in @(
                @{ Name = 'phase8_player_page_overlay_test.dart'; Text = $suite },
                @{ Name = 'player_page_harness.dart'; Text = $harness }
            )) {
                $code = ($pair.Text -split "`n" |
                    Where-Object { $_.TrimStart() -notmatch '^(//|///|\*|/\*)' }) -join "`n"
                if ($code -match 'transientCallbackCount') {
                    throw "$($pair.Name) 用了 transientCallbackCount（恒 ≥1，断言永远为真）"
                }
            }
            Write-Fact 'timer-leak-gate suite=osdTickerRunning seam=debugOsdTickerRunning'
            $global:LASTEXITCODE = 0
        } finally { Pop-Location }
    }

    # 恢复 Debug 产物为「可运行的应用入口」。
    # `flutter test -d windows` 会把测试内核写进应用输出目录，之后双击 exe
    # 会跑集成测试入口而不是应用本身（实测：kernel_blob.bin 里能找到
    # `phase8_overlay_flow_test`）。重建一次即可恢复。
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'restore-debug-artifacts' {
            Push-Location $AppDir
            try { & puro -e $PuroEnvironment -p . flutter build windows --debug } finally { Pop-Location }
        }
    }

    Write-Step 'summary'
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE8-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        exit 0
    } else {
        $summary = "PHASE8-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
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
