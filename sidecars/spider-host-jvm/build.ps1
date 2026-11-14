#!/usr/bin/env pwsh
# 构建 JVM Spider sidecar 宿主（`tvbox-java-v1`，设计文档 §9.3、§9.7、§9.8）。
#
# 产物：sidecars/spider-host-jvm/host.jar + sidecars/spider-host-jvm/lib/*.jar（随包分发）
#
# 设计原则：
#   - **第三方依赖已入库、构建仍不需要联网**：dex 转译需要 dex2jar 2.4.28 闭包（13 个 jar）
#     与 4 个站源常用库（gson / org.json / okhttp / okio），合计约 2.5 MiB、全部 Apache-2.0
#     或 Public Domain（明细见 lib/THIRD-PARTY-NOTICES.md）。这些 jar 随仓库入库，构建只用
#     JDK 自带的 javac/jar，不下载 Gradle/Maven 依赖（§20.5「不依赖开发机上的 PATH、HOME
#     或预装 libmpv」）；
#   - 编译中间产物落在 .build/（已 gitignore），构建后自动清理，只留 host.jar；
#   - `--release 17` 固定字节码版本，保证较新的 JDK 也能加载，且站源源码编译可用；
#   - host.jar 的 MANIFEST 写 Class-Path 指向 lib/*.jar：发布时 host.jar 与 lib/ 必须一起走。
#
# 用法：
#   pwsh -File sidecars/spider-host-jvm/build.ps1
#   pwsh -File sidecars/spider-host-jvm/build.ps1 -Clean
#   pwsh -File sidecars/spider-host-jvm/build.ps1 -DepsSource <dex2jar 目录>   # 首次播种 lib/

[CmdletBinding()]
param(
    [switch]$Clean,
    [int]$Release = 17,
    # 首次播种 lib/ 时从哪里取 jar：该目录下应有 13 个 dex2jar/asm jar 与 lib/ 子目录（4 个三方 jar）。
    # lib/ 齐全时本参数不生效。
    [string]$DepsSource = ''
)

$ErrorActionPreference = 'Stop'
$Here = Resolve-Path $PSScriptRoot
$SrcDir = Join-Path $Here 'src'
# Android 垫片（android.*、com.github.catvod.crawler.*）必须编进 host.jar：站源的
# URLClassLoader 以宿主 loader 为父，垫片在 host.jar 里父加载器就能看到，站源经父委派即可
# 解析 android.* / com.github.catvod.crawler.*，不必把垫片目录加进站源类路径。
$ShimDir = Join-Path $Here 'src-android-shim\src'
$LibDir = Join-Path $Here 'lib'
$BuildDir = Join-Path $Here '.build'
$ClassesDir = Join-Path $BuildDir 'classes'
$JarPath = Join-Path $Here 'host.jar'
$RepoRoot = Resolve-Path (Join-Path $Here '..\..')

if ($Clean) {
    if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
    if (Test-Path $JarPath) { Remove-Item -Force $JarPath }
    Write-Host "已清理构建产物：$BuildDir, $JarPath"
    if (-not (Test-Path $SrcDir)) { return }
}

# 依赖清单：文件名 -> 期望字节数。字节数是**校验和**，用来发现「同名但内容变了」的替换；
# 升级依赖版本时必须同步改这里与 lib/THIRD-PARTY-NOTICES.md。
$Dependencies = [ordered]@{
    # dex2jar 2.4.28 闭包（de.femtopedia.dex2jar，Apache-2.0）
    'asm.jar'           = 126113
    'asm-analysis.jar'  = 35151
    'asm-commons.jar'   = 73498
    'asm-tree.jar'      = 51934
    'asm-util.jar'      = 94559
    'commons-io.jar'    = 538910
    'd2j-base-cmd.jar'  = 13936
    'dex-ir.jar'        = 228347
    'dex-reader-api.jar'= 73111
    'dex-reader.jar'    = 67827
    'dex-tools.jar'     = 160735
    'dex-translator.jar'= 122028
    'dex-writer.jar'    = 103930
    # 第三方库
    'gson-2.11.0.jar'   = 298435
    'json-20240303.jar' = 78332
    'okhttp-3.14.9.jar' = 430488
    'okio-1.17.6.jar'   = 92255
}

# ---------------------------------------------------------------- JDK 17+

# PATH 上的 `java` 在本机是 JRE 8（README §7 已记录）。这里从 javac 反推 JDK，
# 并显式校验主版本，避免误用 Java 8 的 javac（--release 17 会直接失败）。
function Resolve-JdkBin {
    param([int]$MinMajor)

    $candidates = [System.Collections.Generic.List[string]]::new()
    $javac = Get-Command javac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javac) { $candidates.Add((Split-Path $javac.Source)) }
    if ($env:JAVA_HOME) { $candidates.Add((Join-Path $env:JAVA_HOME 'bin')) }
    # 常见安装位置作为兜底：PATH 被旧 JDK 抢占时仍能找到 17+。
    $roots = @(
        (Join-Path $env:ProgramFiles 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Amazon Corretto'),
        (Join-Path $env:ProgramFiles 'Zulu')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { $candidates.Add((Join-Path $_.FullName 'bin')) }
    }

    $seen = @{}
    foreach ($bin in $candidates) {
        if ($seen.ContainsKey($bin)) { continue }
        $seen[$bin] = $true
        $javacExe = Join-Path $bin 'javac.exe'
        $javaExe = Join-Path $bin 'java.exe'
        if (-not ((Test-Path $javacExe) -and (Test-Path $javaExe))) { continue }
        $text = (& $javacExe -version 2>&1) -join ' '
        # 兼容两种输出：`javac 21.0.12`（真 javac）与 `java version "1.8.0_503"`（包装脚本/旧布局）。
        $m = [regex]::Match($text, '(?:(?:javac|version)\s+"?)(\d+)')
        if (-not $m.Success) { continue }
        $major = [int]$m.Groups[1].Value
        if ($major -ge $MinMajor) {
            return [pscustomobject]@{ Bin = $bin; Major = $major; JavaVersion = $text.Trim() }
        }
        Write-Host "跳过 JDK $major（需要 $MinMajor+）：$bin"
    }
    throw "未找到 JDK $MinMajor+（javac 主版本必须 >= $MinMajor）。请安装 JDK 17 或更新版本，或用 JAVA_HOME 指向它。" +
          "注意 PATH 上的 java 可能是 JRE 8，不能用于构建。"
}

$jdk = Resolve-JdkBin -MinMajor 17
$JavacExe = Join-Path $jdk.Bin 'javac.exe'
$JarExe = Join-Path $jdk.Bin 'jar.exe'
Write-Host "使用 JDK：$($jdk.Bin)（$($jdk.JavaVersion)）"

# ---------------------------------------------------------------- lib/ 就位

# 依赖随仓库入库；只有 lib/ 缺件时才从 -DepsSource（默认本地 .probe\d2j）播种，
# 使全新克隆无需联网即可构建。
function Get-DependencySource([string]$name) {
    $dirs = @()
    if ($DepsSource) { $dirs += $DepsSource }
    $dirs += (Join-Path $RepoRoot '.probe\d2j')
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) { continue }
        $direct = Join-Path $dir $name
        if (Test-Path $direct) { return $direct }
        $nested = Join-Path (Join-Path $dir 'lib') $name
        if (Test-Path $nested) { return $nested }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
$missing = @()
foreach ($name in $Dependencies.Keys) {
    $target = Join-Path $LibDir $name
    if ((Test-Path $target) -and (Get-Item $target).Length -eq $Dependencies[$name]) { continue }
    $source = Get-DependencySource $name
    if (-not $source) { $missing += $name; continue }
    Copy-Item -Path $source -Destination $target -Force
    Write-Host "已从 $source 播种 $name"
}
if ($missing.Count -gt 0) {
    throw "lib/ 缺少依赖且本地无来源：$($missing -join ', ')。依赖需随仓库入库，或用 -DepsSource 指向包含它们的目录。"
}

# 自检 1：每个依赖存在、字节数符合清单、且能被当作 zip 打开（损坏的 jar 会让运行时才暴露）。
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($name in $Dependencies.Keys) {
    $path = Join-Path $LibDir $name
    if (-not (Test-Path $path)) { throw "lib/$name 缺失" }
    $length = (Get-Item $path).Length
    if ($length -le 0) { throw "lib/$name 是空文件" }
    if ($length -ne $Dependencies[$name]) {
        throw "lib/$name 字节数不符：实际 $length，期望 $($Dependencies[$name])（版本被替换？请同步更新 build.ps1 与 THIRD-PARTY-NOTICES.md）"
    }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            if ($zip.Entries.Count -eq 0) { throw "无可读条目" }
        } finally { $zip.Dispose() }
    } catch {
        throw "lib/$name 无法被当作 jar 读取：$($_.Exception.Message)"
    }
}
$noticeFile = Join-Path $LibDir 'THIRD-PARTY-NOTICES.md'
if (-not (Test-Path $noticeFile)) { throw 'lib/THIRD-PARTY-NOTICES.md 缺失（许可登记必须随包分发）' }
$noticeText = Get-Content -Path $noticeFile -Raw -Encoding utf8
$unlisted = @($Dependencies.Keys | Where-Object { $noticeText -notmatch [regex]::Escape($_) })
if ($unlisted.Count -gt 0) {
    throw "lib/THIRD-PARTY-NOTICES.md 未登记：$($unlisted -join ', ')"
}
$totalBytes = ($Dependencies.Keys | ForEach-Object { $Dependencies[$_] } | Measure-Object -Sum).Sum
Write-Host "OK lib/ 就位 jars=$($Dependencies.Count) total=$([math]::Round($totalBytes / 1MB, 2))MiB"

# ---------------------------------------------------------------- 编译

# 两个源目录一起编：宿主（src）与 Android 垫片（src-android-shim），垫片随 host.jar 分发。
$sources = @()
foreach ($dir in @($SrcDir, $ShimDir)) {
    if (-not (Test-Path $dir)) { throw "源目录缺失：$dir" }
    $sources += Get-ChildItem -Path $dir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
}
if (-not $sources -or $sources.Count -eq 0) {
    throw "未在 $SrcDir / $ShimDir 找到任何 .java 源文件。"
}

if (Test-Path $ClassesDir) { Remove-Item -Recurse -Force $ClassesDir }
New-Item -ItemType Directory -Force -Path $ClassesDir | Out-Null

# 编译期也要 lib/*.jar：DexIntake 直接使用 asm 与 dex2jar 的 API。
$libJars = Get-ChildItem -Path $LibDir -Filter '*.jar' | Sort-Object Name
$compileClasspath = ($libJars | ForEach-Object { $_.FullName }) -join [System.IO.Path]::PathSeparator

Write-Host "编译 $($sources.Count) 个源文件（--release $Release，classpath=$($libJars.Count) 个 jar）..."
$sources | Set-Content -Path (Join-Path $BuildDir 'sources.txt') -Encoding utf8
& $JavacExe -encoding UTF-8 -proc:none -nowarn --release $Release -classpath $compileClasspath -d $ClassesDir "@$(Join-Path $BuildDir 'sources.txt')"
if ($LASTEXITCODE -ne 0) { throw "javac 失败（exit=$LASTEXITCODE）" }

# ---------------------------------------------------------------- 打包

# 手写 MANIFEST 而不是用 --main-class：只有手写才能同时写 Class-Path。
# 行宽按 JAR 规范折到 72 字节内，续行以单个空格开头。
function Format-ManifestLine {
    param([string]$Name, [string]$Value)
    $line = "${Name}: $Value"
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($line.Length -gt 70) {
        $lines.Add($line.Substring(0, 70))
        $line = ' ' + $line.Substring(70)
    }
    $lines.Add($line)
    return $lines
}

$classPathValue = ($libJars | ForEach-Object { 'lib/' + $_.Name }) -join ' '
$manifestLines = [System.Collections.Generic.List[string]]::new()
$manifestLines.Add('Manifest-Version: 1.0')
foreach ($line in @(Format-ManifestLine -Name 'Main-Class' -Value 'webhtv.spider.Host')) { $manifestLines.Add($line) }
foreach ($line in @(Format-ManifestLine -Name 'Class-Path' -Value $classPathValue)) { $manifestLines.Add($line) }
$manifestPath = Join-Path $BuildDir 'MANIFEST.MF'
[System.IO.File]::WriteAllText($manifestPath, (($manifestLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))

if (Test-Path $JarPath) { Remove-Item -Force $JarPath }
Write-Host "打包 $JarPath ..."
& $JarExe --create --file $JarPath --manifest $manifestPath -C $ClassesDir .
if ($LASTEXITCODE -ne 0) { throw "jar 失败（exit=$LASTEXITCODE）" }

# 自检 2：宿主类必须存在、Main-Class 正确、Class-Path 覆盖 lib/ 全部 jar、
# 且 Class-Path 里每个 jar 在磁盘上真实存在（打包失败时不能静默产出坏 jar）。
# 注意：`jar --describe` 并非所有 JDK 都支持，因此直接读 jar 内的 MANIFEST.MF。
$size = (Get-Item $JarPath).Length
$archive = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
try {
    $manifestEntry = $archive.GetEntry('META-INF/MANIFEST.MF')
    if ($null -eq $manifestEntry) { throw 'host.jar 缺少 META-INF/MANIFEST.MF' }
    $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
    try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $hostEntry = $archive.GetEntry('webhtv/spider/Host.class')
    if ($null -eq $hostEntry) { throw 'host.jar 缺少 webhtv/spider/Host.class' }
    # 垫片必须在 jar 内：站源 loader 通过父委派解析 android.*，缺了就是 NoClassDefFoundError。
    foreach ($shim in @('android/content/Context.class', 'android/content/WebhtvContext.class',
                        'com/github/catvod/crawler/Spider.class')) {
        if ($null -eq $archive.GetEntry($shim)) { throw "host.jar 缺少垫片类 $shim" }
    }
} finally {
    $archive.Dispose()
}
if ($manifestText -notmatch 'Main-Class:\s*webhtv\.spider\.Host') {
    throw "host.jar 的 Main-Class 不是 webhtv.spider.Host，打包异常。"
}
# 折行后的续行以空格开头，先拼回逻辑行再校验。
$logical = $manifestText -replace "`r`n ", ''
foreach ($jar in $libJars) {
    if ($logical -notmatch ('lib/' + [regex]::Escape($jar.Name))) {
        throw "host.jar 的 Class-Path 未包含 lib/$($jar.Name)"
    }
    if (-not (Test-Path (Join-Path $LibDir $jar.Name))) {
        throw "Class-Path 指向的 lib/$($jar.Name) 在磁盘上不存在（发行时必须带上 lib/）"
    }
}
Write-Host "OK host.jar size=$([int]($size / 1024))KiB main-class=webhtv.spider.Host class-path=$($libJars.Count) jar(s)"

# 清理中间产物，只留 host.jar（避免仓库里堆积 .class）。
Remove-Item -Recurse -Force $BuildDir
Write-Host "已清理中间产物 $BuildDir"
