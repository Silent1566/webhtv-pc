#!/usr/bin/env pwsh
# 构建 JVM Spider sidecar 宿主（`tvbox-java-v1`，设计文档 §9.3、§9.7、§9.8）。
#
# 产物：sidecars/spider-host-jvm/host.jar
#
# 设计原则：
#   - **零第三方依赖**：只用 JDK 自带的 javac/jar，不引入 Gradle/Maven 下载，
#     使发行包构建不依赖网络（§20.5「不依赖开发机上的 PATH、HOME 或预装 libmpv」）；
#   - 编译中间产物落在 .build/（已 gitignore），构建后自动清理，只留 host.jar；
#   - `--release 17` 固定字节码版本，保证较新的 JDK 也能加载，且站源源码编译可用。
#
# 用法：
#   pwsh -File sidecars/spider-host-jvm/build.ps1
#   pwsh -File sidecars/spider-host-jvm/build.ps1 -Clean

[CmdletBinding()]
param(
    [switch]$Clean,
    [int]$Release = 17
)

$ErrorActionPreference = 'Stop'
$Here = Resolve-Path $PSScriptRoot
$SrcDir = Join-Path $Here 'src'
$BuildDir = Join-Path $Here '.build'
$ClassesDir = Join-Path $BuildDir 'classes'
$JarPath = Join-Path $Here 'host.jar'

if ($Clean) {
    if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
    if (Test-Path $JarPath) { Remove-Item -Force $JarPath }
    Write-Host "已清理构建产物：$BuildDir, $JarPath"
    if (-not (Test-Path $SrcDir)) { return }
}

foreach ($tool in @('javac', 'jar')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "未找到 $tool；JVM Spider sidecar 需要 JDK（不是 JRE）。"
    }
}

$sources = Get-ChildItem -Path $SrcDir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
if (-not $sources -or $sources.Count -eq 0) {
    throw "未在 $SrcDir 找到任何 .java 源文件。"
}

if (Test-Path $ClassesDir) { Remove-Item -Recurse -Force $ClassesDir }
New-Item -ItemType Directory -Force -Path $ClassesDir | Out-Null

Write-Host "编译 $($sources.Count) 个源文件（--release $Release）..."
$sources | Set-Content -Path (Join-Path $BuildDir 'sources.txt') -Encoding utf8
& javac -encoding UTF-8 -proc:none -nowarn --release $Release -d $ClassesDir "@$(Join-Path $BuildDir 'sources.txt')"
if ($LASTEXITCODE -ne 0) { throw "javac 失败（exit=$LASTEXITCODE）" }

if (Test-Path $JarPath) { Remove-Item -Force $JarPath }
Write-Host "打包 $JarPath ..."
& jar --create --file $JarPath --main-class webhtv.spider.Host -C $ClassesDir .
if ($LASTEXITCODE -ne 0) { throw "jar 失败（exit=$LASTEXITCODE）" }

# 自检：宿主类必须存在且 Main-Class 正确（打包失败时不能静默产出坏 jar）。
# 注意：`jar --describe` 并非所有 JDK 都支持，因此直接读 jar 内的 MANIFEST.MF。
$size = (Get-Item $JarPath).Length
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
try {
    $manifestEntry = $archive.GetEntry('META-INF/MANIFEST.MF')
    if ($null -eq $manifestEntry) { throw 'host.jar 缺少 META-INF/MANIFEST.MF' }
    $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
    try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $hostEntry = $archive.GetEntry('webhtv/spider/Host.class')
    if ($null -eq $hostEntry) { throw 'host.jar 缺少 webhtv/spider/Host.class' }
} finally {
    $archive.Dispose()
}
if ($manifestText -notmatch 'Main-Class:\s*webhtv\.spider\.Host') {
    throw "host.jar 的 Main-Class 不是 webhtv.spider.Host，打包异常。"
}
Write-Host "OK host.jar size=$([int]($size / 1024))KiB main-class=webhtv.spider.Host"

# 清理中间产物，只留 host.jar（避免仓库里堆积 .class）。
Remove-Item -Recurse -Force $BuildDir
Write-Host "已清理中间产物 $BuildDir"
