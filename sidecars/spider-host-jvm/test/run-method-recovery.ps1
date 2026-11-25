[CmdletBinding()]
param(
    [string]$Jdk = '',
    [string]$HostJar = (Join-Path $PSScriptRoot '../host.jar'),
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) ('dex-method-test-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
function Resolve-JdkBin {
    param([int]$MinMajor = 17)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Jdk) {
        $candidates.Add((Join-Path $Jdk 'bin'))
    } else {
        if ($env:JAVA_HOME) { $candidates.Add((Join-Path $env:JAVA_HOME 'bin')) }
        $javac = Get-Command javac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($javac) { $candidates.Add((Split-Path $javac.Source)) }
    }
    foreach ($bin in $candidates | Select-Object -Unique) {
        $javacExe = Join-Path $bin 'javac.exe'
        $javaExe = Join-Path $bin 'java.exe'
        if (-not ((Test-Path $javacExe) -and (Test-Path $javaExe))) { continue }
        $text = (& $javacExe -version 2>&1) -join ' '
        if ($LASTEXITCODE -ne 0) { continue }
        $match = [regex]::Match($text, '(?:(?:javac|version)\s+"?)(\d+)(?:\.(\d+))?')
        if (-not $match.Success) { continue }
        $major = [int]$match.Groups[1].Value
        if ($major -eq 1) { $major = [int]$match.Groups[2].Value }
        if ($major -ge $MinMajor) {
            Write-Host "使用 JDK：$bin（$($text.Trim())）"
            return $bin
        }
    }
    throw "未找到 JDK $MinMajor+。请将 JAVA_HOME 或 PATH 上的 javac 指向 JDK $MinMajor 或更新版本，或传入 -Jdk。"
}
$JdkBin = Resolve-JdkBin

$Here = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$cp = "$HostJar;$Here/lib/*"
& (Join-Path $JdkBin 'javac.exe') --release 17 -encoding UTF-8 -cp $cp -d $WorkDir (Join-Path $PSScriptRoot 'DexMethodRecoveryContractTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $JdkBin 'java.exe') '-Dfile.encoding=UTF-8' '-Dstdout.encoding=UTF-8' '-Dstderr.encoding=UTF-8' -cp "$WorkDir;$cp" webhtv.spider.DexMethodRecoveryContractTest $PSCommandPath (Join-Path $PSHOME 'pwsh.exe')
exit $LASTEXITCODE
