# WebHTV PC · Windows 便携包打包器
#
# 供 GitHub Actions 与本地复现共用：把 `flutter build windows --release` 的
# 产物、sidecar 宿主脚本、构建元数据打成可解压即用的 zip，并输出
# SHA256SUMS.txt / release-info.json。
#
# 设计约束（docs/webhtv-pc-design.md §20.3）：
#   - 只打包主程序、播放器 native 库、sidecar 宿主；**不打包站点源、用户配置、
#     测试 fixture（sidecars/*/spiders、manifests）**；
#   - 必须输出可复现的版本号、构建时间、Git revision、平台标识与签名状态；
#   - 缺任何一个 sidecar 宿主都必须失败，不允许静默产出降级包。
#
# 用法示例：
#   pwsh -File scripts/package_windows.ps1 `
#     -BuildDir apps/desktop-flutter/build/windows/x64/runner/Release `
#     -OutputDir dist `
#     -Version 0.1.0 -BuildNumber 1 -Channel stable `
#     -Commit (git rev-parse HEAD) -FlutterVersion 3.47.5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$BuildNumber = '',

    [ValidateSet('stable', 'beta', 'dev')]
    [string]$Channel = 'stable',

    [string]$Tag = '',

    [string]$Commit = '',

    [string]$ShortCommit = '',

    [string]$FlutterVersion = '',

    [string]$BuiltAt = '',

    [string]$NotesFile = '',

    [string]$RepoRoot = '',

    # 发行包内置的 Node 运行时（Windows x64 node.exe）。官方 LTS：v22.23.4（Jod）。
    [string]$NodeVersion = 'v22.23.4',

    # 离线/CI 旁路：直接指定已存在的 node.exe 所在目录，跳过下载与校验。
    [string]$NodeRuntimeDir = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Message) {
    throw "打包失败：$Message"
}

# 解析随包 node.exe：优先 -NodeRuntimeDir，其次校验通过的 .local 缓存，最后从 nodejs.org
# 下载并按官方 SHASUMS256.txt 校验 SHA-256（并回写 .sha256 旁路文件）。命中缓存也校验，
# 任何一步拿不到可信文件都 Fail，绝不产出降级包。
function Resolve-NodeRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [string]$RuntimeDir = ''
    )

    $nodeFileName = 'node.exe'

    if (-not [string]::IsNullOrWhiteSpace($RuntimeDir)) {
        $explicit = Join-Path $RuntimeDir $nodeFileName
        if (-not (Test-Path -LiteralPath $explicit -PathType Leaf)) {
            Fail "NodeRuntimeDir 下找不到 $nodeFileName：$explicit"
        }
        Write-Host "使用指定的 Node 运行时：$explicit"
        return (Resolve-Path -LiteralPath $explicit).Path
    }

    $cacheSumPath = "$CachePath.sha256"

    # 命中缓存也必须校验：缓存里的 node.exe 是 83 MiB 外部二进制，可能被中断的下载、杀毒
    # 软件或磁盘错误损坏。只有与随缓存保存的官方 sha256 一致才复用，否则按坏文件丢弃，
    # 回落到下面的下载 + 官方 SHASUMS256.txt 校验流程（这是唯一的联网点）。
    if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
        $cachedActual = (Get-FileHash -LiteralPath $CachePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $cachedExpected = ''
        if (Test-Path -LiteralPath $cacheSumPath -PathType Leaf) {
            $cachedExpected = ((Get-Content -LiteralPath $cacheSumPath -First 1) -replace '\s', '').ToLowerInvariant()
        }
        if ($cachedExpected -ne '' -and $cachedExpected -eq $cachedActual) {
            Write-Host "复用已缓存的 Node 运行时：$CachePath（sha256 校验通过：$cachedActual）"
            return $CachePath
        }
        $shownExpected = if ($cachedExpected -eq '') { '<缺失>' } else { $cachedExpected }
        Write-Host "缓存 sha256 不匹配（期望 $shownExpected，实际 $cachedActual），已丢弃缓存并重新下载"
        Remove-Item -LiteralPath $CachePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cacheSumPath -Force -ErrorAction SilentlyContinue
    }

    $distBase = "https://nodejs.org/dist/$Version"
    $sumsUrl = "$distBase/SHASUMS256.txt"
    $nodeUrl = "$distBase/win-x64/$nodeFileName"

    Write-Host "下载 Node 运行时清单：$sumsUrl"
    $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
    $expected = $null
    foreach ($line in ($sums -split "`n")) {
        $parts = ($line.Trim() -split '\s+')
        if ($parts.Count -ge 2 -and $parts[1] -eq "win-x64/$nodeFileName") {
            $expected = $parts[0]
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($expected)) {
        Fail "官方 SHASUMS256.txt 中没有 win-x64/$nodeFileName 条目：$sumsUrl"
    }
    $expected = $expected.ToLowerInvariant()

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CachePath) | Out-Null
    $partial = "$CachePath.part"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    Write-Host "下载 Node $Version：$nodeUrl"
    Invoke-WebRequest -Uri $nodeUrl -OutFile $partial -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Fail "Node 运行时 SHA-256 校验失败（期望 $expected，实际 $actual）：$nodeUrl。已删除下载的坏文件，请重试。"
    }

    Move-Item -LiteralPath $partial -Destination $CachePath -Force
    # 与缓存并列保存官方 sha256（一行小写 hex），供下次命中缓存时离线校验。
    Set-Content -LiteralPath $cacheSumPath -Value $actual -NoNewline -Encoding ascii
    Write-Host "Node 运行时校验通过：sha256=$actual"
    return $CachePath
}

if (-not $IsWindows) {
    Fail '该脚本只适用于 Windows（Authenticode / Compress-Archive 均是 Windows 语义）。'
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "非法版本号 '$Version'，期望 x.y.z（来自 apps/desktop-flutter/pubspec.yaml）。"
}

$buildNumberValue = 0
if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) {
    if ($BuildNumber -notmatch '^\d+$') {
        Fail "非法 build number '$BuildNumber'。"
    }
    $buildNumberValue = [int]$BuildNumber
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not (Test-Path -LiteralPath $BuildDir -PathType Container)) {
    Fail "构建目录不存在：$BuildDir（先执行 flutter build windows --release）。"
}
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).Path

$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$outputRoot = [IO.Path]::GetPathRoot($OutputDir).TrimEnd('\')
if ($OutputDir.TrimEnd('\') -eq $outputRoot) {
    Fail "拒绝把输出目录设为盘符根：$OutputDir"
}
if ($OutputDir.TrimEnd('\') -eq $RepoRoot.TrimEnd('\')) {
    Fail "拒绝把仓库根当作输出目录（会清空工作区）：$OutputDir"
}
if (($BuildDir + '\').StartsWith($OutputDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Fail "输出目录不能是构建目录的上级：$OutputDir"
}

$exeName = 'webhtv_pc.exe'
$exePath = Join-Path $BuildDir $exeName
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Fail "构建目录缺少 $exeName：$BuildDir"
}

# 发行包只带宿主入口及其同目录必需文件；manifests/spiders 是测试 fixture，不得入包。
$sidecarFiles = @(
    'sidecars/spider-host-python/host.py',
    'sidecars/spider-host-python/webhtv_ipc.py',
    'sidecars/spider-host-python/webhtv_catvod.py',
    'sidecars/spider-host-python/base/__init__.py',
    'sidecars/spider-host-python/base/spider.py',
    'sidecars/spider-host-js/host.js',
    'sidecars/spider-host-js/sandbox_worker.js',
    'sidecars/spider-host-js/esm_shim.js',
    'sidecars/spider-host-js/tvbox_globals.js',
    'sidecars/spider-host-js/package.json',
    'sidecars/spider-host-jvm/host.jar'
)
foreach ($relative in $sidecarFiles) {
    $source = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Fail "缺少 sidecar 宿主文件：$relative（发行包必须能定位到 sidecar 宿主）。"
    }
}

# TVBox JS 站源的第三方依赖（cheerio / crypto-js，均为 MIT）随包以目录分发。
# 只有 `runtime: node-tvbox` 才会惰性 require，`runtime: node` 完全不加载。
# JVM 宿主 host.jar 的 MANIFEST Class-Path 全部按相对 host.jar 所在目录解析到同级 lib/，
# 缺件时 JVM 静默忽略缺失 jar（纯 jar 站源照旧可跑，含 classes.dex 的站源必然失败），
# 所以 lib/ 也必须随包，且缺失提示要按目录给出各自的生成方式。
$sidecarDependencyDirs = [ordered]@{
    'sidecars/spider-host-js/node_modules' = '先在 sidecars/spider-host-js 下执行 npm install --omit=dev'
    'sidecars/spider-host-jvm/lib'         = '运行 sidecars/spider-host-jvm/build.ps1 生成 lib/'
}
foreach ($relative in $sidecarDependencyDirs.Keys) {
    $source = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Fail "缺少 sidecar 依赖目录：$relative（$($sidecarDependencyDirs[$relative])）。"
    }
}

# Node 运行时：Windows 发行包随包内置 node.exe（用户无需自备 Node）。
if ($NodeVersion -notmatch '^v\d+\.\d+\.\d+$') {
    Fail "非法 Node 版本号 '$NodeVersion'，期望 vX.Y.Z（如 v22.23.4）。"
}
$nodeCachePath = Join-Path (Join-Path (Join-Path $RepoRoot '.local\nodejs') $NodeVersion) 'node.exe'
$nodeExeSource = Resolve-NodeRuntime -Version $NodeVersion -CachePath $nodeCachePath -RuntimeDir $NodeRuntimeDir
$nodeRelativePath = 'runtime/node/node.exe'

$suffix = switch ($Channel) {
    'beta' { '-beta' }
    'dev' { '-dev' }
    default { '' }
}
$folderName = "WebHTV-PC-$Version$suffix-windows-x64"
$zipName = "webhtv-pc-$Version$suffix-windows-x64.zip"

if ([string]::IsNullOrWhiteSpace($BuiltAt)) {
    $BuiltAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($Commit)) {
        Fail '无法确定 Git commit；请显式传 -Commit。'
    }
    $Commit = $Commit.Trim()
}
if ([string]::IsNullOrWhiteSpace($ShortCommit)) {
    $ShortCommit = $Commit.Substring(0, [Math]::Min(7, $Commit.Length))
}

$utf8 = [Text.UTF8Encoding]::new($false)

Write-Host "WebHTV PC 打包：version=$Version build=$buildNumberValue channel=$Channel commit=$ShortCommit"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Get-ChildItem -LiteralPath $OutputDir -Force | Remove-Item -Recurse -Force

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('webhtv-pkg-' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $stagingRoot $folderName

try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    # 1. 主程序与播放器 native 库
    Copy-Item -Path (Join-Path $BuildDir '*') -Destination $staging -Recurse -Force

    # 2. sidecar 宿主（与 exe 同级；spider_registry.dart 的发行包布局）
    foreach ($relative in $sidecarFiles) {
        $destination = Join-Path $staging $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $destination -Force
    }
    foreach ($relative in $sidecarDependencyDirs.Keys) {
        $destination = Join-Path $staging $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $destination -Recurse -Force
    }

    # 2.5 JVM 依赖闭包自检：host.jar 的 MANIFEST Class-Path 是按相对 host.jar 所在目录解析的，
    # 而缺失 jar 只会被 JVM 静默忽略，所以必须在打包阶段逐条断言其真实落到 staging，
    # 否则会产出「纯 jar 站源能跑、含 classes.dex 的站源必失败」的隐性降级包。
    $jvmRelative = 'sidecars/spider-host-jvm'
    $jvmJarStaged = Join-Path $staging "$jvmRelative/host.jar"
    $jvmLibSource = Join-Path $RepoRoot "$jvmRelative/lib"
    $jvmLibStaged = Join-Path $staging "$jvmRelative/lib"
    if (-not (Test-Path -LiteralPath $jvmLibStaged -PathType Container)) {
        Fail "staging 缺少 JVM 依赖目录：$jvmRelative/lib"
    }
    $jvmLibSourceNames = @(Get-ChildItem -LiteralPath $jvmLibSource -File -Filter '*.jar').Name
    $jvmLibStagedNames = @(Get-ChildItem -LiteralPath $jvmLibStaged -File -Filter '*.jar').Name
    $jvmLibMissingNames = @($jvmLibSourceNames | Where-Object { $_ -notin $jvmLibStagedNames })
    $jvmLibExtraNames = @($jvmLibStagedNames | Where-Object { $_ -notin $jvmLibSourceNames })
    if ($jvmLibMissingNames.Count -gt 0 -or $jvmLibExtraNames.Count -gt 0) {
        Fail ("JVM 依赖目录与源目录不一致（$jvmRelative/lib）：源 $($jvmLibSourceNames.Count) 个、staging $($jvmLibStagedNames.Count) 个；" +
            "缺失 $($jvmLibMissingNames -join '、')；多出 $($jvmLibExtraNames -join '、')")
    }

    # MANIFEST 折行以「换行 + 单个空格」续行，先展开再按空白切分，才能拿到完整相对路径列表。
    $jvmZip = [IO.Compression.ZipFile]::OpenRead($jvmJarStaged)
    try {
        $jvmManifestEntry = $jvmZip.GetEntry('META-INF/MANIFEST.MF')
        if ($null -eq $jvmManifestEntry) {
            Fail "host.jar 缺少 META-INF/MANIFEST.MF：$jvmRelative/host.jar"
        }
        $jvmManifestReader = [IO.StreamReader]::new($jvmManifestEntry.Open())
        try {
            $jvmManifestText = $jvmManifestReader.ReadToEnd()
        } finally {
            $jvmManifestReader.Dispose()
        }
    } finally {
        $jvmZip.Dispose()
    }
    $jvmManifestUnfolded = ($jvmManifestText -replace "`r`n", "`n") -replace "`n ", ''
    $jvmClassPathLine = $jvmManifestUnfolded -split "`n" |
        Where-Object { $_ -match '^Class-Path:' } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($jvmClassPathLine)) {
        Fail "host.jar 的 MANIFEST 没有 Class-Path，无法校验 JVM 依赖闭包：$jvmRelative/host.jar"
    }
    $jvmClassPathEntries = ($jvmClassPathLine -replace '^Class-Path:\s*', '') -split '\s+' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $jvmJarDirStaged = Split-Path -Parent $jvmJarStaged
    $jvmMissing = [System.Collections.Generic.List[string]]::new()
    foreach ($entryPath in $jvmClassPathEntries) {
        if (-not (Test-Path -LiteralPath (Join-Path $jvmJarDirStaged ($entryPath -replace '/', '\')) -PathType Leaf)) {
            $jvmMissing.Add("$jvmRelative/$entryPath")
        }
    }
    if ($jvmMissing.Count -gt 0) {
        Fail "host.jar 的 MANIFEST Class-Path 有 $($jvmMissing.Count) 个依赖未随包落地：$($jvmMissing -join '、')"
    }

    # 3. 内置 Node 运行时（spider_registry.dart 在 exe 同级 runtime/node/ 下查找 node.exe）
    $nodeDestination = Join-Path $staging $nodeRelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nodeDestination) | Out-Null
    Copy-Item -LiteralPath $nodeExeSource -Destination $nodeDestination -Force
    if (-not (Test-Path -LiteralPath $nodeDestination -PathType Leaf)) {
        Fail "随包 Node 运行时拷贝失败：$nodeRelativePath"
    }
    $nodeFile = Get-Item -LiteralPath $nodeDestination
    $nodeVersionText = $nodeFile.VersionInfo.FileVersion

    # 4. 签名状态以 Authenticode 实测为准，不靠发布脚本开关猜。
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $staging $exeName)
    $statusText = if ($signature) { $signature.Status.ToString() } else { 'UnknownError' }
    $signatureStatus = if ($statusText -eq 'Valid') {
        'valid'
    } elseif ($statusText -eq 'NotSigned') {
        'unsigned'
    } else {
        'invalid'
    }
    $signatureSubject = $null
    if ($signature -and $signature.SignerCertificate) {
        $signatureSubject = $signature.SignerCertificate.Subject
    }
    $signatureLabel = switch ($signatureStatus) {
        'valid' { '已签名（Authenticode 校验通过）' }
        'unsigned' { '未签名' }
        default { "签名无效（$statusText）" }
    }

    # 5. 完整性标签与网络锁定归位。
    # exe 一旦继承 Low 完整性标签，双击启动的进程就是 Low IL，对 Medium 的
    # %APPDATA% / %LOCALAPPDATA% 只读：用户看到「数据库打开失败、设置写不进去」，
    # 而 icacls 显示权限一切正常。带 Zone.Identifier 的文件还会触发 SmartScreen。
    # 现场记录：docs/troubleshooting/readonly-storage-low-integrity.md
    # BuildDir 一并归位：用户经常直接双击 build 产物，而不是解压 zip。
    # 对目录本身设标签需要 WRITE_OWNER，temp 目录常只继承到 Modify（会报 Access
    # is denied），但子文件归位仍然成立，所以这里只告警、不阻断打包。
    $integrityLabel = 'Medium'
    $integrityFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($integrityTarget in @($BuildDir, $staging)) {
        if (-not (Test-Path -LiteralPath $integrityTarget)) { continue }
        $integrityOutput = icacls $integrityTarget /setintegritylevel "(OI)(CI)$integrityLabel" /T /C 2>&1
        $failedCount = 0
        foreach ($line in $integrityOutput) {
            if ("$line" -match 'Failed processing\s+(\d+)\s+files') { $failedCount += [int]$Matches[1] }
        }
        if ($LASTEXITCODE -ne 0 -or $failedCount -gt 0) {
            $integrityFailures.Add("$integrityTarget（失败 $failedCount 项，退出码 $LASTEXITCODE）")
        }
    }
    $integritySummary = if ($integrityFailures.Count -eq 0) {
        "$integrityLabel（已归位）"
    } else {
        "$integrityLabel（部分未归位：$($integrityFailures -join '；')）"
    }
    if ($integrityFailures.Count -gt 0) {
        Write-Warning "完整性标签归位未完全成功：$($integrityFailures -join '；')"
    }

    $unblockedCount = 0
    foreach ($stagedFile in (Get-ChildItem -LiteralPath $staging -Recurse -File -Force)) {
        if (Get-Item -LiteralPath $stagedFile.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
            Unblock-File -LiteralPath $stagedFile.FullName -ErrorAction Stop
            $unblockedCount++
        }
    }
    $unblockSummary = if ($unblockedCount -eq 0) { '无需解除（无网络来源标记）' } else { "$unblockedCount 个文件已解除" }

    # 6. 构建信息（UTF-8 无 BOM，中文可读）
    $buildInfo = @"
WebHTV PC 构建信息
==================
版本：$Version (build $buildNumberValue)
通道：$Channel
Git commit：$Commit
构建时间（UTC）：$BuiltAt
Flutter：$FlutterVersion
平台：Windows x64
签名：$signatureLabel
程序：$exeName
完整性标签：$integritySummary
网络锁定：$unblockSummary

Sidecar 宿主（随包）：Python / Node / JVM
- Node 运行时（随包内置）：$nodeRelativePath（约 $([Math]::Round($nodeFile.Length / 1MB, 1)) MiB）
  - 打包用版本：$NodeVersion；node.exe FileVersion：$(if ([string]::IsNullOrWhiteSpace($nodeVersionText)) { '未知' } else { $nodeVersionText })
  - 用户机器无需自行安装 Node。
- Python 与 JVM 宿主仍只带入口脚本，不含解释器：对应站源需要本机安装 Python 3 或 JDK 17+，缺失时应用会明确提示「运行时未安装」。
- 第三方许可见 data/flutter_assets/NOTICES.Z。
"@
    [IO.File]::WriteAllText((Join-Path $staging 'BUILD_INFO.txt'), $buildInfo + "`n", $utf8)

    # 7. 随包文件清单（动态库版本 + SHA-256；不逐项列 flutter_assets）
    $inventory = [System.Collections.Generic.List[string]]::new()
    $inventory.Add('随包文件清单（主程序 / 动态库 / Sidecar 宿主 / 内置 Node 运行时）')
    $inventory.Add("完整性标签：$integritySummary；网络锁定：$unblockSummary")
    $inventory.Add('flutter_assets 内的资源与第三方许可不逐项列出；许可见 data/flutter_assets/NOTICES.Z。')
    $inventory.Add('')

    $targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    Get-ChildItem -LiteralPath $staging -File |
        Where-Object { $_.Name -notin @('BUILD_INFO.txt', 'THIRD_PARTY.txt') } |
        ForEach-Object { $targets.Add($_) }
    foreach ($relative in @('data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z')) {
        $candidate = Join-Path $staging $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $targets.Add((Get-Item -LiteralPath $candidate))
        }
    }
    foreach ($relative in $sidecarFiles) {
        $targets.Add((Get-Item -LiteralPath (Join-Path $staging $relative)))
    }
    $targets.Add((Get-Item -LiteralPath (Join-Path $staging $nodeRelativePath)))
    # 依赖目录逐文件入清单会让清单膨胀到 1200+ 行，这里按目录汇总许可与版本来源。
    $inventory.Add('sidecars/spider-host-js/node_modules/  第三方依赖目录：cheerio (MIT)、crypto-js (MIT)；逐包版本见 sidecars/spider-host-js/package-lock.json')
    $inventory.Add('sidecars/spider-host-jvm/lib/  第三方依赖目录：host.jar 的 MANIFEST Class-Path 闭包，逐 jar 版本见文件名')

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in ($targets | Sort-Object -Property FullName)) {
        if (-not $seen.Add($file.FullName)) { continue }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $relative = [IO.Path]::GetRelativePath($staging, $file.FullName).Replace('\', '/')
        $fileVersion = $file.VersionInfo.FileVersion
        $versionLabel = if ([string]::IsNullOrWhiteSpace($fileVersion)) { '未知' } else { $fileVersion }
        $inventory.Add(('{0}  sha256={1}  version={2}' -f $relative, $hash, $versionLabel))
    }
    [IO.File]::WriteAllText(
        (Join-Path $staging 'THIRD_PARTY.txt'),
        (($inventory -join "`n") + "`n"),
        $utf8
    )

    # 8. zip（含顶层目录，解压即得可运行目录）
    $zipPath = Join-Path $OutputDir $zipName
    Compress-Archive -LiteralPath $staging -DestinationPath $zipPath -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Fail "zip 未生成：$zipPath"
    }
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # 9. 校验文件（LF 行尾，sha256sum -c 兼容）
    [IO.File]::WriteAllText(
        (Join-Path $OutputDir 'SHA256SUMS.txt'),
        "$zipHash  $zipName`n",
        $utf8
    )

    # 10. 机器可读发布元数据（供未来 updater / 分发使用；当前应用不消费）
    $notes = ''
    if (-not [string]::IsNullOrWhiteSpace($NotesFile) -and (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
        $notes = (Get-Content -LiteralPath $NotesFile -Raw -Encoding utf8)
    }
    $info = [ordered]@{
        schema      = 1
        product     = 'WebHTV PC'
        version     = $Version
        build       = $buildNumberValue
        channel     = $Channel
        tag         = if ([string]::IsNullOrWhiteSpace($Tag)) { $null } else { $Tag }
        commit      = $Commit
        shortCommit = $ShortCommit
        builtAt     = $BuiltAt
        platform    = 'windows'
        arch        = 'x64'
        flutter     = $FlutterVersion
        signature   = [ordered]@{
            status  = $signatureStatus
            subject = $signatureSubject
        }
        integrity   = [ordered]@{
            label          = $integrityLabel
            complete       = ($integrityFailures.Count -eq 0)
            failures       = @($integrityFailures)
            unblockedFiles = $unblockedCount
        }
        assets      = @(
            [ordered]@{
                name   = $zipName
                size   = (Get-Item -LiteralPath $zipPath).Length
                sha256 = $zipHash
            }
        )
        runtimes    = [ordered]@{
            # 宿主入口脚本一律随包；解释器各自是否随包看下面两项。
            bundledHosts = @('python', 'node', 'jvm')
            bundled = @(
                [ordered]@{
                    id          = 'node'
                    version     = $NodeVersion
                    path        = $nodeRelativePath
                    sha256      = (Get-FileHash -LiteralPath (Join-Path $staging $nodeRelativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
                    fileVersion = if ([string]::IsNullOrWhiteSpace($nodeVersionText)) { $null } else { $nodeVersionText }
                }
            )
            requiresLocal = @('Python 3', 'JDK 17+')
        }
        notes       = $notes
    }
    $json = ($info | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText((Join-Path $OutputDir 'release-info.json'), $json + "`n", $utf8)

    Write-Host "打包完成：$zipPath"
    Write-Host "SHA256：$zipHash"
    Write-Host "校验文件：$(Join-Path $OutputDir 'SHA256SUMS.txt')"
    Write-Host "发布元数据：$(Join-Path $OutputDir 'release-info.json')"
    Write-Host "完整性：$integrityLabel；网络锁定：$unblockSummary"
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
