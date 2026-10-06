# WebHTV PC Phase 3 验收脚本（直播 + 字幕 + 弹幕 · Windows）
#
# 一条命令跑完 Phase 3 验收门禁（docs/phase3/README.md §3）：
#   0. 直播清单 + 字幕 + 弹幕 fixture 预检（Content-Type 正确、越权 403/404）
#   1. 契约与 fixture 测试（Python）+ 直播清单 Schema 校验
#   1.5 JVM sidecar 预检（host.jar + JDK 17+ + 真实握手，§9.3）
#   2. 静态检查（dart analyze）
#   3. 单元测试（flutter test，含 phase3_* 直播/诊断/字幕/弹幕/直播弹幕/JVM 门禁套件）
#   4. Windows 集成测试（真实窗口 + 真实播放器；直播/字幕/弹幕/直播弹幕/解析器/EPG/JS/JVM/猫源/T4，-d windows）
#   5. 汇总并输出 PHASE3-ACCEPT 可复查事实行
#
# 设计原则与 Phase 1/2 保持一致：
#   - 失败不静默：每个步骤独立捕获退出码，失败记入 $script:Failures；
#   - 原生命令 stderr 不作为失败判据（PowerShell 7.3+ 会把原生 stderr 提升为
#     终止性错误，必须关闭该行为，仅以退出码判定）；
#   - 所有事实行写入 docs/phase3/evidence/windows-acceptance.txt，可复查。
#
# 用法：
#   pwsh -File tools/phase3/run_windows_acceptance.ps1
#   pwsh -File tools/phase3/run_windows_acceptance.ps1 -SkipIntegrationTests

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
$EvidenceDir = Join-Path $RepoRoot 'docs\phase3\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 3 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null

function Write-Step {
    param([string]$Message)
    $line = "PHASE3-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE3-ACCEPT $Message"
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

# 判定一次 `flutter test` 输出是否只是 **flutter_tools 自身的临时目录竞态**。
#
# 背景（实测）：集成套件偶发出现
#
# ```
# 00:00 +0: <用例名> - did not complete [E]
# 00:00 +0: Some tests failed.
# unhandled error during finalization of test:
# PathNotFoundException: Deletion failed,
#   path = 'F:\temp\flutter_tools.<hash>\flutter_test_listener.<hash>'
# ```
#
# 特征是：**时间戳停在 00:00**（用例体一行未执行、无 PHASE3-EVIDENCE 输出）、
# 失败原因是 `flutter_tools` 在 finalize 阶段删不掉自己的监听目录。这是工具链的
# 临时目录竞态（本项目把 TEMP 放在 F:，且与 `rm -rf /f/temp/flutter_tools.*` 一类
# 清理并发），不是被测代码失败。这里对它**重跑一次**并在证据里明确记下；
# 其它任何失败（包括真实断言失败）一律不重试，保持门禁不被重试掩盖。
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
# 因此这里主动探测「能 import jsonschema」的解释器并钉住它；
# 探测全部失败时退回原行为（裸 `py`），由门禁自己报错，不静默跳过。
function Resolve-PythonWithJsonschema {
    $attempts = @(
        @{ Exe = 'py'; Args = @('-3.13') },
        @{ Exe = 'py'; Args = @('-3.12') },
        @{ Exe = 'py'; Args = @('-3.11') },
        @{ Exe = 'py'; Args = @('-3.10') },
        @{ Exe = 'python'; Args = @() },
        @{ Exe = 'python3'; Args = @() }
    )
    foreach ($attempt in $attempts) {
        if (-not (Get-Command $attempt.Exe -ErrorAction SilentlyContinue)) { continue }
        $probe = & $attempt.Exe @($attempt.Args + @('-c', 'import sys, jsonschema; print(sys.executable)')) 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe) { return $probe.Trim() }
    }
    return $null
}

$resolvedPython = Resolve-PythonWithJsonschema
if ($resolvedPython) {
    $python = $resolvedPython
    Write-Fact "python interpreter with-jsonschema=$python"
} else {
    $python = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }
    Write-Fact "python interpreter fallback=$python (未找到带 jsonschema 的解释器)"
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
    $stdout = Join-Path $RepoRoot '.local\tmp\webhtv-fixture-phase3.log'
    # `Start-Process` 在**继承的环境变量**里会把端口/基址一并传下去。
    # 背景（实测）：`flutter test` 启动的 Windows 测试进程会读到父进程的环境变量，
    # 而 `test/fixture_support.dart` 的 `fixtureBaseUrl` 优先取 `WEBHTV_FIXTURE_BASE`。
    # 若外层 shell 残留了指向**已停止的旧 fixture 实例**的值（如
    # `http://127.0.0.1:7975`），直播/弹幕等集成用例会去连那个死端口，报
    # `SocketException: 远程计算机拒绝网络连接 … port = 7975`，而本脚本启动的
    # fixture 服务完全健康——表现为“门禁随机失败”。这里显式覆盖，保证测试
    # 进程总是连到本次启动的 fixture 服务（`$FixturePort`）。
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"
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

    # 0) fixture 预检：直播清单三格式、字幕与弹幕（含 Header 门禁）形态正确。
    # 先固定测试进程可见的 fixture 基址（见 Start-FixtureServer 的注释）。
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"
    Invoke-Checked 'live-fixture-preflight' {
        function Fetch($path) {
            & curl.exe -s -o NUL -w '%{http_code}|%{content_type}' "http://127.0.0.1:$FixturePort$path"
        }
        function FetchWithMediaHeaders($path) {
            & curl.exe -s -o NUL -w '%{http_code}|%{content_type}' `
                -H 'Referer: http://127.0.0.1:18080/' `
                -H 'User-Agent: WebHTV-PC/0.1 (Windows)' `
                "http://127.0.0.1:$FixturePort$path"
        }
        $m3u = Fetch '/live/live.m3u'
        $txt = Fetch '/live/live.txt'
        $json = Fetch '/live/live.json'
        $missing = Fetch '/live/nope.m3u'
        # 字幕（§10.3）：/media/ 有 Header 门禁，字幕与视频同源同门禁。
        $srtDenied = Fetch '/media/sample.srt'
        $srt = FetchWithMediaHeaders '/media/sample.srt'
        $playSubs = Fetch '/api/play-with-subs'
        # 弹幕（§21 Phase 3）：与媒体/字幕同一道 Header 门禁。
        $dXmlDenied = Fetch '/danmaku/sample.xml'
        $dXml = FetchWithMediaHeaders '/danmaku/sample.xml'
        $dTxt = FetchWithMediaHeaders '/danmaku/sample.txt'
        $playDanmaku = Fetch '/api/play-with-danmaku'
        # 解析器（§12）：解析器端点必须 200，解析服务故障必须 500（不静默）。
        $parseType1 = Fetch '/api/parse/type1'
        $parseRequired = Fetch '/api/play-parse-required'
        $parseError = Fetch '/api/parse/always-error'
        # T4 播放入口（§8.1 分发顺序 5）：`play=<剧集目标>&flag=<线路>` 必须真实可用。
        $t4Direct = Fetch '/api/type4/?play=t4-direct&flag=a115'
        $t4Parse = Fetch '/api/type4/?play=t4-parse&flag=a115'
        $t4NoUrl = Fetch '/api/type4/?play=t4-nourl&flag=a115'
        $t4Biz = Fetch '/api/type4/?play=t4-bizerr&flag=a115'
        # EPG（§13.3）：XMLTV fixture 必须 200 且为 XML 类型；坏 EPG 地址 404。
        $epg = Fetch '/live/epg.xml'
        $epgMissing = Fetch '/live/nope-epg.xml'
        $liveBrokenEpg = Fetch '/live/live-broken-epg.m3u'
        $log = "preflight m3u=$m3u txt=$txt json=$json missing=$missing " +
               "srt-denied=$srtDenied srt=$srt play-with-subs=$playSubs " +
               "danmaku-denied=$dXmlDenied danmaku-xml=$dXml danmaku-txt=$dTxt " +
               "play-with-danmaku=$playDanmaku parse-type1=$parseType1 " +
               "play-parse-required=$parseRequired parse-error=$parseError " +
               "t4-direct=$t4Direct t4-parse=$t4Parse t4-nourl=$t4NoUrl t4-bizerr=$t4Biz " +
               "epg=$epg epg-missing=$epgMissing live-broken-epg=$liveBrokenEpg"
        if (-not $m3u.StartsWith('200|')) { throw "M3U live 应 200，实际 $m3u" }
        if (-not $txt.StartsWith('200|')) { throw "TXT live 应 200，实际 $txt" }
        if (-not $json.StartsWith('200|')) { throw "JSON live 应 200，实际 $json" }
        if (-not $missing.StartsWith('404')) { throw "缺失 live 应 404，实际 $missing" }
        if (-not $srtDenied.StartsWith('403')) { throw "缺 Header 的字幕应 403，实际 $srtDenied" }
        if (-not $srt.StartsWith('200|application/x-subrip')) { throw "带 Header 的 SRT 应 200 且为 application/x-subrip，实际 $srt" }
        if (-not $playSubs.StartsWith('200|')) { throw "带 subs 的播放结果应 200，实际 $playSubs" }
        if (-not $dXmlDenied.StartsWith('403')) { throw "缺 Header 的弹幕应 403，实际 $dXmlDenied" }
        if (-not $dXml.StartsWith('200|application/xml')) { throw "带 Header 的弹幕 XML 应 200 且为 application/xml，实际 $dXml" }
        if (-not $dTxt.StartsWith('200|')) { throw "带 Header 的弹幕 TXT 应 200，实际 $dTxt" }
        if (-not $playDanmaku.StartsWith('200|')) { throw "带 danmaku 的播放结果应 200，实际 $playDanmaku" }
        if (-not $parseType1.StartsWith('200|')) { throw "解析器端点应 200，实际 $parseType1" }
        if (-not $parseRequired.StartsWith('200|')) { throw "parse=1 播放结果应 200，实际 $parseRequired" }
        if (-not $parseError.StartsWith('500')) { throw "解析服务故障应 500（不静默），实际 $parseError" }
        if (-not $t4Direct.StartsWith('200|')) { throw "T4 播放入口（直链样本）应 200，实际 $t4Direct" }
        if (-not $t4Parse.StartsWith('200|')) { throw "T4 播放入口（parse=1 样本）应 200，实际 $t4Parse" }
        if (-not $t4NoUrl.StartsWith('200|')) { throw "T4 播放入口（无地址样本）应 200，实际 $t4NoUrl" }
        if (-not $t4Biz.StartsWith('200|')) { throw "T4 播放入口（业务错误样本）应 200，实际 $t4Biz" }
        if (-not $epg.StartsWith('200|application/xml')) { throw "EPG XMLTV 应 200 且为 application/xml，实际 $epg" }
        if (-not $epgMissing.StartsWith('404')) { throw "缺失 EPG 应 404，实际 $epgMissing" }
        if (-not $liveBrokenEpg.StartsWith('200|')) { throw "坏 EPG 地址的直播清单应 200（清单本身可用），实际 $liveBrokenEpg" }
        # 事实行必须写进证据文件，而不是只打到控制台（证据要可复查）。
        # `Write-Host` 会随 Invoke-Checked 的输出一起落盘，`Write-Fact` 再补一条带前缀的。
        Write-Fact $log
    }

    # 1) Python 契约测试 + Schema 校验（与 Phase 2 共用同一套）。
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

    # 1.5) JVM sidecar 预检（§9.3 `tvbox-java-v1`，ADR-0002）。
    #
    # 必须**先**确认宿主与站源可用，否则后面的 `phase3_jvm_spider_test.dart` 会以
    # 「启动即崩」的形式失败，掩盖真正原因。这里独立探测并输出可复查事实行：
    #   - host.jar 是否存在（缺失时提示先跑 build.ps1）；
    #   - 本机是否有 Java 17+（**只按 PATH 取第一个 java.exe 会拿到 JRE 1.8**）；
    #   - 宿主能否完成一次握手（用 fixture 站源，不依赖网络）。
    Invoke-Checked 'jvm-host-preflight' {
        $jvmDir = Join-Path $RepoRoot 'sidecars\spider-host-jvm'
        $jar = Join-Path $jvmDir 'host.jar'
        $entry = Join-Path $jvmDir 'spiders\fixture\FixtureSpider.java'
        $manifest = Join-Path $jvmDir 'manifests\fixture.json'

        if (-not (Test-Path $jar)) {
            throw "缺少 $jar；请先运行 pwsh -File sidecars/spider-host-jvm/build.ps1"
        }

        # 选一个 >= 17 的 java（与 Dart 侧 `probeJavaRuntime` 同规则）。
        $java = $null
        $rejected = @()
        $candidates = @()
        if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\java.exe') }
        foreach ($dir in ($env:PATH -split ';' | Where-Object { $_ })) {
            $candidates += (Join-Path $dir 'java.exe')
        }
        foreach ($candidate in ($candidates | Select-Object -Unique)) {
            if (-not (Test-Path $candidate)) { continue }
            $versionText = (& $candidate -version 2>&1 | Out-String)
            if ($versionText -match 'version\s+"(\d+)(?:\.(\d+))?') {
                $major = [int]$Matches[1]
                if ($major -eq 1 -and $Matches[2]) { $major = [int]$Matches[2] }
            } else {
                $rejected += "$candidate (版本无法识别)"
                continue
            }
            if ($major -lt 17) {
                $rejected += "$candidate (Java $major < 17)"
                continue
            }
            # 源码入口需要 javac（JDK 而非 JRE）。
            if (-not (Test-Path (Join-Path (Split-Path $candidate) 'javac.exe'))) {
                $rejected += "$candidate (Java $major，但无 javac，无法编译 .java 入口)"
                continue
            }
            $java = $candidate
            Write-Fact "jvm-java selected=$candidate major=$major"
            break
        }
        if (-not $java) {
            throw "未找到可用的 JDK 17+（已尝试 $($candidates.Count) 个候选）：$($rejected -join '; ')"
        }

        $logDir = Join-Path $RepoRoot '.local\tmp'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $stderrLog = Join-Path $logDir 'jvm-host-preflight.stderr.log'
        $frames = @(
            '{"jsonrpc":"2.0","id":"pf-1","method":"initialize","params":{"abi":"webhtv-ipc-v1","abiMajor":1,"abiMinor":0,"siteKey":"jvm-fixture","extend":""},"deadlineMs":30000}',
            '{"jsonrpc":"2.0","id":"pf-2","method":"destroy","params":{},"deadlineMs":10000}'
        )
        $frameText = ''
        foreach ($frame in $frames) {
            $payload = [System.Text.Encoding]::UTF8.GetBytes($frame)
            $frameText += "Content-Length: $($payload.Length)`r`nContent-Type: application/json; charset=utf-8`r`n`r`n$frame"
        }
        $frameFile = Join-Path $logDir 'jvm-host-preflight.frames.txt'
        # 帧必须是精确字节（Content-Length 按 UTF-8 字节数），用无 BOM UTF-8 写入。
        [System.IO.File]::WriteAllText($frameFile, $frameText, [System.Text.UTF8Encoding]::new($false))

        # `-Xmx` 必须显式给出：宿主用 Windows 作业对象把内存限制为 256 MiB，
        # 而 JVM 默认按物理内存 1/4 预留堆（本机 640 MiB）会直接启动失败。
        $output = cmd.exe /c "`"$java`" -Xmx128m -Xms16m -jar `"$jar`" --entry `"$entry`" --manifest `"$manifest`" < `"$frameFile`" 2> `"$stderrLog`""
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String)
        if ($exitCode -ne 0) {
            $stderrText = if (Test-Path $stderrLog) { Get-Content $stderrLog -Raw } else { '' }
            throw "JVM 宿主退出码 $exitCode；stderr=$stderrText"
        }
        if ($text -notmatch 'webhtv-ipc-v1') {
            throw "JVM 宿主未返回 webhtv-ipc-v1 握手响应；stdout=$text"
        }
        if ($text -notmatch '"id"\s*:\s*"pf-1"') {
            throw "JVM 宿主握手响应缺少 initialize 结果；stdout=$text"
        }
        Write-Fact "jvm-host handshake=ok abi=webhtv-ipc-v1 entry=FixtureSpider.java"
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

    # 3) 单元测试（含 phase3_* 直播/诊断/字幕/弹幕门禁套件；自带进程内 fixture 服务，可独立运行）。
    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter test
        } finally {
            Pop-Location
        }
    }

    # 3.5) 猫源真实 bundle 端到端（导入 → 站点 → 搜索 → 播放）。
    #
    # 只有在 `CAT_PACKAGE`（或默认 F:\temp\catpkg）存在时才跑：本机没准备真实
    # bundle 时跳过并记事实行，而不是把门禁判死（真实 bundle 属于验收环境，不入库）。
    $catPackage = if ($env:CAT_PACKAGE) { $env:CAT_PACKAGE } else { 'F:\temp\catpkg' }
    if (Test-Path (Join-Path $catPackage 'index.js')) {
        Invoke-Checked 'cat-source-real-bundle' {
            & $python (Join-Path $RepoRoot 'tools\phase3\verify_cat_source.py') --package $catPackage --timeout 90
        }
    } else {
        Write-Step 'cat-source-real-bundle (跳过)'
        Write-Fact "cat-source-real-bundle skipped package=$catPackage"
    }

    # 4) Windows 集成测试（真实窗口 + 真实播放器 + 直播直链 + 外挂字幕 + 静态/直播弹幕
    #    + 解析器 + EPG + JS Spider + 猫源 bundle + T4）。
    #
    # 每个套件单独跑（`-d windows` 一次只能跑一个文件）。抽成函数是为了给
    # `flutter_tools` 临时目录竞态留一次重跑机会（见 `Test-FlutterToolsTempRace`）。
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
                # 猫源集成测试需要真实 bundle 目录（CAT_PACKAGE）；未准备时整组用例
                # 自重跳过并记证据行，不会把门禁判死。
                if (-not $env:CAT_PACKAGE -and (Test-Path (Join-Path $catPackage 'index.js'))) {
                    $env:CAT_PACKAGE = $catPackage
                }
                # 明确重置退出码：`Invoke-Checked` 以 `$LASTEXITCODE` 判成败，
                # 而本块在**全部套件都通过**时必须回 0（否则上一次失败的退出码会残留）。
                $global:LASTEXITCODE = 0
                $suites = @(
                    'integration_test/live_flow_test.dart',
                    'integration_test/subtitle_flow_test.dart',
                    'integration_test/danmaku_flow_test.dart',
                    'integration_test/live_danmaku_flow_test.dart',
                    'integration_test/parser_flow_test.dart',
                    'integration_test/epg_flow_test.dart',
                    'integration_test/js_spider_flow_test.dart',
                    # PC Java Spider（§9.3 `tvbox-java-v1`，ADR-0002）：真实 JVM 子进程。
                    'integration_test/jvm_spider_flow_test.dart',
                    'integration_test/cat_source_flow_test.dart',
                    # T4（`type=4` HTTP API + Base64 ext）播放入口（§8.1 分发顺序 5、§7.4.8）：
                    # 真实 AT 配置 → T4 站点 → 分类 → 详情 → 播放入口 → 可播地址。
                    # 配置地址不可达时用例自重跳过并记证据行，不会把门禁判死。
                    'integration_test/t4_play_flow_test.dart',
                    # T4 全站扫描门禁（§8.1 分发顺序 5）：真实 AT 配置里的**每一个**
                    # `type=4` 站点都不得产出 `playbackParserRequired`（用户报告的
                    # 「未声明 playUrl」错误类）。抽查会漏掉剧集目标形态退化，
                    # 因此这里扫全站。配置地址不可达时用例自重跳过。
                    'integration_test/t4_sweep_flow_test.dart',
                    # 详情页竞态（§8.3、§17.2）：真实窗口复现「详情 A → 返回 → 立刻详情 B」，
                    # 锁定「迟到的 A 不得覆盖 B」「离开详情页清空状态」。
                    'integration_test/detail_race_flow_test.dart',
                    # MVP-A 全链路（§21 Phase 1）：配置导入 → 首页 → 分类 → 详情 → 播放 → 历史。
                    'integration_test/mvp_a_flow_test.dart'
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

    # 4.5) 恢复 Debug 产物为「可运行的应用入口」。
    #
    # 背景（真实缺陷，实测复现）：`flutter test <file> -d windows` 会把**测试**的
    # 内核快照写进应用自己的输出目录
    # `build/windows/x64/runner/Debug/data/flutter_assets/kernel_blob.bin`，
    # 而 `webhtv_pc.exe` 仍指向同一个目录。于是跑完第 4 步后，双击
    # `build/windows/x64/runner/Debug/webhtv_pc.exe` 启动的是集成测试入口：
    # 它既不执行 `lib/main.dart`（Dart 侧 startup-trace 一行不写），
    # 也不在 `-d windows` 之外报告失败——表现为「进程活着、窗口创建了但从不
    # 显示（首帧永不到达）、无任何报错」，极易被误判为「程序坏了」。
    #
    # 实测对照：污染前 kernel_blob 含 `lib/main.dart` 入口、无 integration_test
    # 符号；跑一次集成测试后被换成 48 处 integration_test 符号、main.dart 入口消失。
    #
    # 因此验收收尾必须重建一次，保证交付目录里的 exe 是可直接双击运行的应用，
    # 而不是测试壳。这也让「跑完门禁 → 手动打开 exe 验收」的流程始终成立。
    #
    # 无条件执行（不受 `-SkipIntegrationTests` 影响）：污染可能来自**此前**手动
    # 跑过的集成测试，而不是本次运行。重建幂等且增量下很快，代价远低于交付一个
    # 打不开的 exe。
    Invoke-Checked 'restore-debug-artifacts' {
        Push-Location $AppDir
        try {
            & puro -e $PuroEnvironment -p . flutter build windows --debug
        } finally {
            Pop-Location
        }
    }

    # 4.6) 产物可运行性门禁：确认 Debug 产物确实是应用入口。
    #
    # 仅靠 4.5 重建还不够——重建也可能因为缓存或参数变化而产出错误入口。
    # 这里直接读 kernel_blob 的符号表做**正向断言**：必须出现 `lib/main.dart`
    # 入口，且不得出现集成测试入口。这样“产物被换成测试壳”会在门禁里显式失败，
    # 而不是留给用户双击后发现没界面。
    #
    # 同样无条件执行：这是纯只读检查，代价极低，却是「exe 能打开」的唯一机器判据。
    Invoke-Checked 'debug-artifact-runnable' {
        $kernel = Join-Path $AppDir 'build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin'
        if (-not (Test-Path $kernel)) {
            # 必须抛异常而不是 `exit`：`exit` 会终止整个脚本，跳过
            # `Invoke-Checked` 的失败记录与第 5 步汇总，使门禁“静默失败”。
            throw "kernel_blob 缺失：$kernel"
        }
        # 按字节读入并转 Latin-1，避免中文/UTF-8 解码开销与非法字节抛错。
        $bytes = [System.IO.File]::ReadAllBytes($kernel)
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $hasMainEntry = $text.Contains('lib/main.dart') -or $text.Contains('lib\main.dart')
        $testMarkers = ([regex]::Matches($text, 'integration_test')).Count
        Write-Fact "debug-artifact-runnable kernel=$kernel main-entry=$hasMainEntry integration-test-markers=$testMarkers"
        if (-not $hasMainEntry -or $testMarkers -gt 0) {
            throw "Debug 产物入口不是 lib/main.dart（main-entry=$hasMainEntry integration-test-markers=$testMarkers，疑似被集成测试覆盖）"
        }
    }

    # 5) 汇总。
    Write-Step 'summary'
    # 如实反映是否跳过了集成测试，避免 `-SkipIntegrationTests` 时仍声称 gates=all。
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE3-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        Write-Host "PHASE3-ACCEPT 全部门禁通过，详见 $LogFile"
        exit 0
    } else {
        $summary = "PHASE3-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
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