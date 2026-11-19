<#
.SYNOPSIS
    准备 / 校验 / 落盘 Windows 随包的 libmpv（完整 FFmpeg 构建）。

.DESCRIPTION
    为什么不用 media_kit 归档里那一份：`media_kit_libs_windows_video` 拉的
    `mpv-dev-x86_64-20230924-git-652a1dd.7z`（media-kit/libmpv-win32-video-build，
    2023-09 之后就没再发版）里的 libavfilter **没有滤镜表**——实测连
    `lavfi=[anull]` 都报 `No such filter`。后果是音量归一在 Windows 上不可能生效：
    裸名 `af=dynaudnorm` 被内核拒（rc=-9，安全但没效果），`af=lavfi=[dynaudnorm]`
    更糟——属性写成功、建链失败，mpv 会把整条音轨丢掉（用户变哑）。
    详见 docs/reference/libmpv-windows.md。

    这里换成 shinchiro/mpv-winbuild-cmake 的完整 FFmpeg 构建（mpv 官方安装页推荐的
    Windows 构建源，每日更新），按"归档 SHA256 + 解出的 DLL SHA256"双重钉死，
    并支持三种模式：
      * 默认：下载 + 校验 + 解压到 $CacheDir/libmpv-2.dll（可离线复用）；
      * -VerifyPath <file>：只校验某份 libmpv-2.dll 是不是 pin 的这份（CI 用）；
      * -ApplyBuildDir <dir>：把 pin 的 DLL 覆盖进 Flutter 的 Windows 构建树
        （<dir> = apps/desktop-flutter/build/windows/x64），覆盖
        <dir>/libmpv/ 与 <dir>/runner/Release/ 两处，并复验。

.PARAMETER CacheDir
    缓存目录，默认 <repo>/.local/libmpv-windows（.local 被 .gitignore 忽略）。

.PARAMETER Offline
    只允许使用已缓存的归档；缺失或校验不符直接失败，不联网。

.PARAMETER ApplyBuildDir
    覆盖目标构建树根目录（含 libmpv/ 与 runner/Release/ 的那一层）。

.PARAMETER VerifyPath
    只校验这份 libmpv-2.dll，不下载、不落盘。
#>
[CmdletBinding()]
param(
    [string]$CacheDir = '',
    [switch]$Offline,
    [string]$ApplyBuildDir = '',
    [string]$VerifyPath = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CacheDir) { $CacheDir = Join-Path $RepoRoot (Join-Path '.local' 'libmpv-windows') }

# 钉死的构建：shinchiro/mpv-winbuild-cmake 的 20261111 tag（tag 不可变）。
# 归档里 mpv-dev-*.7z 含 libmpv-2.dll + 头文件；我们只用 DLL。
$ArchiveName = 'mpv-dev-x86_64-20261111-git-bcde6b93cc.7z'
$ArchiveUrl = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261111/$ArchiveName"
$ArchiveSha256 = '273c079b11ea5575822f972756f4c9a71149a5c10130353abeb8586738938452'
# 解出的 libmpv-2.dll 的 SHA256：随包与 CI 校验都用它，避免"归档对、DLL 被换"。
$DllSha256 = '88504ee5560942a955405e99dfb5971368e4cf851321f36565bf2a667271db1b'
$DllBytes = 121789952
$MpvVersion = 'v0.42.0-38-gbcde6b93c'
$FfmpegVersion = 'N-128766-gcd4e96eb3'
$SourceLabel = 'shinchiro/mpv-winbuild-cmake @ 20261111（mpv v0.42.0-38-gbcde6b93c / FFmpeg N-128766-gcd4e96eb3）'

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PinnedDll([string]$Path, [string]$Context) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "缺少 libmpv-2.dll（$Context）：$Path" }
    $actual = Get-Sha256 $Path
    if ($actual -ne $DllSha256) {
        $size = (Get-Item -LiteralPath $Path).Length
        throw "libmpv-2.dll 不是 pin 的构建（$Context）：sha256=$actual size=$size，期望 $DllSha256（$DllBytes 字节）。它决定 Windows 上音量归一与 LUT 能不能用，不允许降级成 media_kit 归档里那份无滤镜表的 DLL。"
    }
    Write-Host "verified    libmpv-2.dll（$Context）$MpvVersion $DllSha256"
}

# --- 只校验 ------------------------------------------------------------------
if ($VerifyPath) {
    Assert-PinnedDll $VerifyPath 'VerifyPath'
    return
}

# --- 准备缓存 ----------------------------------------------------------------
$archivePath = Join-Path $CacheDir $ArchiveName
$dllPath = Join-Path $CacheDir 'libmpv-2.dll'

if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}

if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $actual = Get-Sha256 $archivePath
    if ($actual -ne $ArchiveSha256) {
        Write-Warning "缓存归档校验不符（sha256=$actual），删除后重取：$archivePath"
        Remove-Item -LiteralPath $archivePath -Force
    }
}

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    if ($Offline) { throw "缺少缓存的 $ArchiveName，且指定了 -Offline：$archivePath" }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe 是准备 Windows 构建依赖的必需工具' }
    $partial = "$archivePath.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Host "downloading $ArchiveName"
    & curl.exe --fail --location --silent --show-error --retry 3 --retry-delay 2 --max-time 900 --output $partial $ArchiveUrl
    if ($LASTEXITCODE -ne 0) { throw "下载失败（curl exit $LASTEXITCODE）：$ArchiveUrl" }
    $actual = Get-Sha256 $partial
    if ($actual -ne $ArchiveSha256) { throw "归档 SHA256 不匹配：$actual，期望 $ArchiveSha256" }
    Move-Item -LiteralPath $partial -Destination $archivePath -Force
    Write-Host "downloaded  $ArchiveName"
}

$extractRoot = Join-Path $CacheDir 'extract'
if (-not (Test-Path -LiteralPath (Join-Path $extractRoot 'libmpv-2.dll') -PathType Leaf)) {
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { throw 'tar.exe（bsdtar，支持 7z）是解包 Windows 构建依赖的必需工具' }
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    & tar.exe -xf $archivePath -C $extractRoot
    if ($LASTEXITCODE -ne 0) { throw "解包失败（tar exit $LASTEXITCODE）：$archivePath" }
}
Assert-PinnedDll (Join-Path $extractRoot 'libmpv-2.dll') 'archive'
Copy-Item -LiteralPath (Join-Path $extractRoot 'libmpv-2.dll') -Destination $dllPath -Force

$manifest = [ordered]@{
    source        = $SourceLabel
    archiveUrl    = $ArchiveUrl
    archiveSha256 = $ArchiveSha256
    dllSha256     = $DllSha256
    dllBytes      = $DllBytes
    mpvVersion    = $MpvVersion
    ffmpegVersion = $FfmpegVersion
    license       = 'mpv 为 GPLv2+（部分组件 LGPL）；FFmpeg 按编译选项为 GPL/LGPL。源码获取：mpv.io / ffmpeg.org'
    cachedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
[IO.File]::WriteAllText(
    (Join-Path $CacheDir 'manifest.json'),
    ($manifest | ConvertTo-Json) + "`n",
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Host "cached      $dllPath"

# --- 落盘到构建树 ------------------------------------------------------------
if ($ApplyBuildDir) {
    $resolved = (Resolve-Path -LiteralPath $ApplyBuildDir).Path
    # media_kit 的 CMake 解压出来的那份（单测走 PATH 时会先命中它）与最终产物那份。
    $targets = @(
        (Join-Path $resolved 'libmpv/libmpv-2.dll'),
        (Join-Path $resolved 'runner/Release/libmpv-2.dll')
    )
    $applied = 0
    foreach ($target in $targets) {
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        Copy-Item -LiteralPath $dllPath -Destination $target -Force
        Assert-PinnedDll $target 'ApplyBuildDir'
        $applied++
    }
    if ($applied -eq 0) {
        throw "构建树里没有可覆盖的 libmpv 目录（$resolved）：先 flutter build windows 再执行本脚本。"
    }
    Write-Host "applied     $applied 处 libmpv-2.dll → $resolved"
}
