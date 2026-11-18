[CmdletBinding()]
param(
    [string]$CacheDir = '',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CacheDir) { $CacheDir = Join-Path $RepoRoot (Join-Path '.local' 'win-deps') }

# Flutter's Windows plugin CMakeLists fetch these with file(DOWNLOAD) calls that
# carry no timeout: a stalled socket parks the build at
# "Building Windows application..." for hours with no output. Fetch them once
# here under hard time limits; native builds only ever read this cache.
$Artifacts = @(
    [pscustomobject]@{
        Name      = 'nuget.exe'
        Subdir    = ''
        Url       = 'https://dist.nuget.org/win-x86-commandline/v5.10.0/nuget.exe'
        Algorithm = 'SHA256'
        Hash      = '852b71cc8c8c2d40d09ea49d321ff56fd2397b9d6ea9f96e532530307bbbafd3'
    },
    [pscustomobject]@{
        Name      = 'mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Subdir    = ''
        Url       = 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Algorithm = 'MD5'
        Hash      = 'a832ef24b3a6ff97cd2560b5b9d04cd8'
    },
    [pscustomobject]@{
        Name      = 'ANGLE.7z'
        Subdir    = ''
        Url       = 'https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z'
        Algorithm = 'MD5'
        Hash      = 'e866f13e8d552348058afaafe869b1ed'
    },
    [pscustomobject]@{
        Name      = 'microsoft.windows.implementationlibrary.1.0.220914.1.nupkg'
        Subdir    = 'nuget-local'
        Url       = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.implementationlibrary/1.0.220914.1/microsoft.windows.implementationlibrary.1.0.220914.1.nupkg'
        Algorithm = 'SHA256'
        Hash      = 'b6b1d55bc8df309105cd7733fd200cccc678d703b61b31398a63a146a7148b09'
    },
    [pscustomobject]@{
        Name      = 'sqlite-autoconf-3520000.tar.gz'
        Subdir    = ''
        Url       = 'https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz'
        Algorithm = 'SHA256'
        Hash      = 'f6b50b0c103392af32a8be15b2b9d25959de9a00a70c3979128aafeaa5338b3f'
    },
    [pscustomobject]@{
        Name      = 'microsoft.web.webview2.1.0.1210.39.nupkg'
        Subdir    = 'nuget-local'
        Url       = 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.1210.39/microsoft.web.webview2.1.0.1210.39.nupkg'
        Algorithm = 'SHA256'
        Hash      = 'd67144c38d18196af4c20d3e28c5cc1dcc0971f69c688032e3159fe37903f8d3'
    }
)

function Get-ArtifactHash([string]$Path, [string]$Algorithm) {
    (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is required to fetch the pinned Windows build dependencies' }

$results = @()
$missing = 0
foreach ($artifact in $Artifacts) {
    $directory = if ($artifact.Subdir) { Join-Path $CacheDir $artifact.Subdir } else { $CacheDir }
    $target = Join-Path $directory $artifact.Name
    if (Test-Path -LiteralPath $target) {
        $actual = Get-ArtifactHash $target $artifact.Algorithm
        if ($actual -eq $artifact.Hash) {
            Write-Host "cached      $($artifact.Name)"
            $results += [pscustomobject]@{ name = $artifact.Name; sha256 = (Get-ArtifactHash $target 'SHA256'); size = (Get-Item -LiteralPath $target).Length }
            continue
        }
        Write-Host "corrupted   $($artifact.Name) ($($artifact.Algorithm.ToLowerInvariant()) $actual)"
        Remove-Item -LiteralPath $target -Force
    }
    if ($Offline) {
        Write-Host "missing     $($artifact.Name)"
        $missing++
        continue
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $partial = "$target.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Host "downloading $($artifact.Name)"
    # --speed-limit/--speed-time turn a stalled peer into a fast, explicit
    # failure instead of an indefinite wait.
    & curl.exe --fail --silent --show-error --location --max-time 900 --speed-limit 1024 --speed-time 60 --output $partial $artifact.Url
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-Host "failed      $($artifact.Name) (curl exit $LASTEXITCODE)"
        $missing++
        continue
    }
    $actual = Get-ArtifactHash $partial $artifact.Algorithm
    if ($actual -ne $artifact.Hash) {
        Remove-Item -LiteralPath $partial -Force
        Write-Host "failed      $($artifact.Name) ($($artifact.Algorithm.ToLowerInvariant()) $actual)"
        $missing++
        continue
    }
    Move-Item -LiteralPath $partial -Destination $target -Force
    Write-Host "fetched     $($artifact.Name)"
    $results += [pscustomobject]@{ name = $artifact.Name; sha256 = (Get-ArtifactHash $target 'SHA256'); size = (Get-Item -LiteralPath $target).Length }
}

if ($missing -gt 0) {
    throw "$missing of $($Artifacts.Count) Windows build dependencies are unavailable; rerun scripts/prepare_windows_native_deps.ps1 without -Offline"
}

# sqlite3_flutter_libs pulls the amalgamation with FetchContent; hand it an
# extracted tree instead (FETCHCONTENT_SOURCE_DIR_SQLITE3 in
# apps/desktop-flutter/windows/runner/native_deps_cache.cmake).
$sqliteSourceRoot = Join-Path $CacheDir 'sqlite3-src'
$sqliteSourceDir = Join-Path $sqliteSourceRoot 'sqlite-autoconf-3520000'
if (-not (Test-Path -LiteralPath (Join-Path $sqliteSourceDir 'sqlite3.c'))) {
    if ($Offline) { throw "Missing extracted sqlite3 sources in $sqliteSourceDir; rerun without -Offline" }
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { throw 'tar.exe is required to unpack the sqlite3 amalgamation' }
    New-Item -ItemType Directory -Force -Path $sqliteSourceRoot | Out-Null
    & tar.exe -xzf (Join-Path $CacheDir 'sqlite-autoconf-3520000.tar.gz') -C $sqliteSourceRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to unpack the sqlite3 amalgamation (tar exit $LASTEXITCODE)" }
}
Write-Host "cached      sqlite-autoconf-3520000 (sources)"

[pscustomobject]@{
    schemaVersion = 1
    platform      = 'windows-x64'
    artifacts     = $results
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $CacheDir 'manifest.json') -Encoding utf8
Write-Host "Windows build dependencies ready: $CacheDir"
