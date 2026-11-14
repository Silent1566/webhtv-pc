[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$CacheDir = '',
    [string]$LockFile = '',
    [switch]$Offline,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'

function Assert-RuntimeRelativePath([string]$Path) {
    if (-not $Path -or $Path.Contains('\') -or $Path.Contains(':') -or $Path.StartsWith('/') -or $Path -match '[\x00-\x1f<>"|?*]') { throw "Unsafe relative path: $Path" }
    foreach ($part in $Path.Split('/')) {
        if ($part -in @('', '.', '..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { throw "Unsafe relative path: $Path" }
    }
}

function Assert-RuntimeDirectory([string]$Path, [string]$Repo) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe workspace directory: $full" }
    $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
    Assert-RuntimeRelativePath $relative
    if ($relative -ne 'runtime/python' -and -not $relative.StartsWith('.local/', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe runtime output/cache directory: $full" }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe reparse ancestor: $current" }
        }
        if ($current -eq $root) { break }
        $current = Split-Path -Parent $current
    }
    return $full
}

function Read-RuntimeLock([string]$Path) {
    $lock = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($lock.schemaVersion -ne 1 -or $lock.platform -ne 'windows-x64' -or $lock.python.version -notmatch '^3\.(13|14)\.\d+$') { throw 'Invalid runtime lock platform/version/schema' }
    $expected = @('requests','urllib3','charset-normalizer','idna','certifi','pycryptodome','lxml','beautifulsoup4','soupsieve','typing-extensions') | Sort-Object
    $names = @($lock.packages.name | Sort-Object)
    if ($names.Count -ne 10 -or ($names -join ',') -ne ($expected -join ',')) { throw 'Incomplete or duplicate wheel closure' }
    $tag = 'cp' + (($lock.python.version -split '\.')[0..1] -join '')
    if ($lock.python.filename -ne "python-$($lock.python.version)-embed-amd64.zip" -or $lock.python.url -ne "https://www.python.org/ftp/python/$($lock.python.version)/$($lock.python.filename)" -or $lock.python.evidenceUrl -ne "$($lock.python.url).sigstore") { throw 'Invalid official Python artifact URL' }
    foreach ($artifact in @($lock.python) + @($lock.packages)) {
        Assert-RuntimeRelativePath $artifact.filename
        if ($artifact.filename.Contains('/') -or $artifact.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $artifact.size -lt 1 -or $artifact.size -gt 64MB) { throw 'Invalid locked artifact size/hash/name' }
    }
    foreach ($package in $lock.packages) {
        if ($package.version -notmatch '^\d+(\.\d+)*$' -or ($package.name -eq 'pycryptodome' -and [version]$package.version -ge [version]'4.0')) { throw 'Invalid locked package version' }
        $stem = [regex]::Escape($package.name.Replace('-', '_') + '-' + $package.version)
        $compatible = "^$stem-($tag-$tag-win_amd64|cp3[7-9]-abi3-win_amd64|py3-none-any|py2\.py3-none-any)\.whl$"
        if ($package.filename -notmatch $compatible -or $package.url -notmatch '^https://files\.pythonhosted\.org/packages/' -or ([uri]$package.url).Segments[-1] -ne $package.filename -or $package.evidenceUrl -ne "https://pypi.org/pypi/$($package.name)/$($package.version)/json") { throw "Invalid or incompatible wheel: $($package.filename)" }
    }
    if ($lock.assembled -isnot [pscustomobject] -or $lock.assembled.archiveSha256 -isnot [string] -or $lock.assembled.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Missing trusted locked assembly digest' }
    foreach ($key in @('size','expandedSize','fileCount')) {
        if (($lock.assembled.$key -isnot [int] -and $lock.assembled.$key -isnot [long]) -or $lock.assembled.$key -lt 1) { throw 'Invalid trusted locked assembly limits' }
    }
    if ($lock.assembled.size -gt 128MB -or $lock.assembled.expandedSize -gt 128MB -or $lock.assembled.fileCount -gt 10000) { throw 'Trusted locked assembly exceeds caps' }
    return $lock
}

function Get-RuntimeArtifact($Artifact, [string]$Cache, [switch]$Offline) {
    Assert-RuntimeRelativePath $Artifact.filename
    $path = Join-Path $Cache $Artifact.filename
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe artifact reparse point: $path" }
        if ($item.Length -ne $Artifact.size -or $item.Length -gt 64MB -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Artifact.sha256) { throw "SHA256/size mismatch in cached artifact: $path" }
        return $path
    }
    if ($Offline) { throw "Offline cache miss: $($Artifact.filename)" }
    if ($script:RuntimeRequests -ge 50) { throw 'HTTP request limit exceeded' }
    $script:RuntimeRequests++
    $partial = "$path.$([guid]::NewGuid().ToString('N')).part"
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    & $curl --fail --silent --show-error --max-time 900 --max-filesize 67108864 --output $partial $Artifact.url
    if ($LASTEXITCODE -ne 0) { throw "Official artifact download failed: $($Artifact.filename), curl exit $LASTEXITCODE; partial retained at $partial" }
    if ((Get-Item -LiteralPath $partial).Length -ne $Artifact.size -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Artifact.sha256) { throw "SHA256/size mismatch downloading $($Artifact.filename)" }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($partial)) -ne [IO.Path]::GetFullPath($Cache).TrimEnd('\') -or (Test-Path -LiteralPath $path)) { throw 'Unsafe cache move target' }
    Write-Host "Verified $($Artifact.filename) sha256=$($Artifact.sha256)"
    Move-Item -LiteralPath $partial -Destination $path
    return $path
}

function Expand-RuntimeArchive([string]$Archive, [string]$Destination, [hashtable]$Budget) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $path = $entry.FullName
            if ($path.EndsWith('/')) { Assert-RuntimeRelativePath $path.TrimEnd('/'); continue }
            Assert-RuntimeRelativePath $path
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Unsafe ZIP symlink: $path" }
            if (-not $seen.Add($path)) { throw "Duplicate archive path: $path" }
            $Budget.files++; $Budget.bytes += $entry.Length
            if ($Budget.files -gt 10000 -or $Budget.bytes -gt 128MB) { throw 'Expanded runtime exceeds file/size cap' }
            $full = [IO.Path]::GetFullPath((Join-Path $Destination $path))
            if (-not $full.StartsWith([IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe archive destination: $full" }
            if (Test-Path -LiteralPath $full) { throw "Archive would overwrite existing file: $path" }
            $entries.Add(@{entry=$entry;full=$full})
        }
        foreach ($record in $entries) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $record.full) -Force | Out-Null
            $source = $record.entry.Open(); $target = [IO.File]::Open($record.full, [IO.FileMode]::CreateNew)
            try {
                $buffer = [byte[]]::new(65536); $written = 0L
                while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $written += $count
                    if ($written -gt $record.entry.Length) { throw 'ZIP expanded size mismatch' }
                    $target.Write($buffer, 0, $count)
                }
                if ($written -ne $record.entry.Length) { throw 'ZIP expanded size mismatch' }
            } finally { $source.Dispose(); $target.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Invoke-RuntimeProbe([string]$Directory, $Lock) {
    $code = @'
import sys, json, pathlib, importlib.metadata as m
import requests, Crypto, lxml.etree, bs4
from Crypto.Cipher import AES
root = pathlib.Path(sys.executable).resolve().parent
lock = json.loads(sys.argv[1])
assert sys.version.split()[0] == lock['python']['version'], sys.version
assert sys.flags.isolated and sys.flags.dont_write_bytecode
assert all(pathlib.Path(p).resolve().is_relative_to(root) for p in sys.path), sys.path
for package in lock['packages']:
    assert m.version(package['name']) == package['version'], package['name']
    for requirement in m.requires(package['name']) or []:
        if ';' not in requirement:
            name = requirement.split('>')[0].split('<')[0].split('=')[0].split('!')[0].strip()
            assert m.version(name), requirement
assert len(AES.new(b'0'*16, AES.MODE_ECB).encrypt(b'1'*16)) == 16
assert lxml.etree.fromstring(b'<ok/>').tag == 'ok'
assert bs4.BeautifulSoup('<b>ok</b>', 'html.parser').b.text == 'ok'
assert requests.Request('GET', 'https://example.invalid').prepare().method == 'GET'
print(json.dumps({'pythonVersion':sys.version.split()[0], 'executable':sys.executable, 'isolated':True, 'probeModules':['requests','Crypto','lxml','bs4']}))
'@
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $Directory 'python.exe'
    $psi.WorkingDirectory = $Directory
    $psi.UseShellExecute = $false
    foreach ($arg in @('-I','-B','-c',$code,($Lock | ConvertTo-Json -Depth 12 -Compress))) { $psi.ArgumentList.Add($arg) }
    $psi.Environment.Remove('PYTHONHOME') | Out-Null
    $psi.Environment.Remove('PYTHONPATH') | Out-Null
    $psi.Environment['PATH'] = Join-Path $env:SystemRoot 'System32'
    $process = [Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Native Python probe timed out' }
    if ($process.ExitCode -ne 0) { throw "Native Python probe failed: exit $($process.ExitCode)" }
    $process.Dispose()
}

function Get-RuntimeStreamHash($Stream, [long]$ExpectedSize, [hashtable]$Budget) {
    if ($ExpectedSize -lt 0 -or $ExpectedSize -gt 128MB -or $Budget.bytes + $ExpectedSize -gt 128MB) { throw 'Runtime actual size budget exceeded' }
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(65536)
    $head = [byte[]]::new([math]::Min(4096, $ExpectedSize))
    $read = 0L
    try {
        while ($read -lt $ExpectedSize) {
            $limit = [int][math]::Min($buffer.Length, $ExpectedSize - $read)
            $count = $Stream.Read($buffer, 0, $limit)
            if ($count -eq 0) { throw 'Runtime actual size is shorter than declared size' }
            if ($read -lt $head.Length) { [Array]::Copy($buffer, 0, $head, [int]$read, [int][math]::Min($count, $head.Length - $read)) }
            $read += $count; $Budget.bytes += $count
            $sha.AppendData($buffer, 0, $count)
        }
        if ($Stream.ReadByte() -ne -1) { $Budget.bytes++; throw 'Runtime actual size exceeds declared size' }
        return [pscustomobject]@{sha256=[Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant();head=$head}
    } finally { $sha.Dispose() }
}

function Assert-RuntimePeHeader([byte[]]$Header, [string]$Path) {
    if ($Header.Length -lt 64 -or $Header[0] -ne 0x4d -or $Header[1] -ne 0x5a) { throw "Invalid native implementation/ABI: $Path" }
    $offset = [BitConverter]::ToInt32($Header, 60)
    if ($offset -lt 64 -or $offset + 6 -gt $Header.Length -or $Header[$offset] -ne 0x50 -or $Header[$offset+1] -ne 0x45 -or $Header[$offset+2] -ne 0 -or $Header[$offset+3] -ne 0 -or [BitConverter]::ToUInt16($Header, $offset+4) -ne 0x8664) { throw "Invalid native implementation/ABI: $Path" }
}

function Test-PythonRuntimeBundle([string]$Directory, $Lock) {
    $items = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($items.Count -ne 2 -or @($items | Where-Object {$_.Name -cnotin @('bundle.json','python-runtime.zip') -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count) { throw 'Runtime must contain only bundle.json and python-runtime.zip' }
    $manifest = Join-Path $Directory 'bundle.json'
    $archive = Join-Path $Directory 'python-runtime.zip'
    $archiveSize = (Get-Item -LiteralPath $archive).Length
    if ($archiveSize -lt 1 -or $archiveSize -gt 128MB) { throw 'Runtime archive size cap exceeded' }
    if ((Get-Item -LiteralPath $manifest).Length -gt 8MB) { throw 'Manifest exceeds size cap' }
    $bundle = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if ($bundle -isnot [pscustomobject] -or (($bundle.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'archive,archiveSha256,files,packages,platform,probeModules,pythonVersion,schemaVersion') { throw 'Invalid bundle schema/contract' }
    if (($bundle.schemaVersion -isnot [int] -and $bundle.schemaVersion -isnot [long]) -or $bundle.schemaVersion -ne 1 -or $bundle.probeModules -isnot [array] -or $bundle.packages -isnot [array] -or $bundle.files -isnot [array]) { throw 'Invalid bundle schema types' }
    foreach ($key in @('pythonVersion','platform','archive','archiveSha256')) {
        if ($bundle.$key -isnot [string]) { throw "Invalid bundle schema string: $key" }
    }
    if ($bundle.pythonVersion -cne $Lock.python.version -or $bundle.platform -cne 'windows-x64' -or $bundle.archive -cne 'python-runtime.zip' -or $bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or $bundle.probeModules.Count -ne 4 -or @($bundle.probeModules | Where-Object {$_ -isnot [string]}).Count -or ($bundle.probeModules -join ',') -cne 'requests,Crypto,lxml,bs4') { throw 'Invalid bundle schema/contract values' }
    $expectedPackages = @($Lock.packages | Sort-Object name | ForEach-Object { "$($_.name)=$($_.version)" })
    $actualPackages = @($bundle.packages | Sort-Object name | ForEach-Object {
        if ($_ -isnot [pscustomobject] -or (($_.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'name,version' -or $_.name -isnot [string] -or $_.version -isnot [string]) { throw 'Invalid package schema' }
        "$($_.name)=$($_.version)"
    })
    if (($expectedPackages -join ',') -cne ($actualPackages -join ',')) { throw 'Incomplete bundle package closure' }
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $declared = 0L
    foreach ($file in $bundle.files) {
        if ($file -isnot [pscustomobject] -or (($file.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'path,sha256,size' -or $file.path -isnot [string] -or $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or ($file.size -isnot [int] -and $file.size -isnot [long]) -or $file.size -lt 0 -or $file.size -gt 128MB) { throw 'Invalid runtime file entry schema' }
        Assert-RuntimeRelativePath $file.path
        if ($file.path -ceq 'bundle.json' -or $file.path -match '(^|/)(__pycache__|spiders|manifests|\.git)(/|$)' -or $map.ContainsKey($file.path)) { throw 'Invalid/duplicate runtime file entry' }
        $declared += $file.size
        if ($declared -gt 128MB -or $map.Count -ge 10000) { throw 'Bundle exceeds expanded file/size cap' }
        $map.Add($file.path, $file)
    }
    if (-not $map.Count) { throw 'Empty bundle files schema' }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entryBytes = 0L
        foreach ($entry in $zip.Entries) {
            Assert-RuntimeRelativePath $entry.FullName
            if (-not $seen.Add($entry.FullName) -or -not $map.ContainsKey($entry.FullName) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unexpected/duplicate/unsafe ZIP entry' }
            if ($entry.Length -ne $map[$entry.FullName].size -or $entry.Length -lt 0 -or $entry.Length -gt 128MB) { throw "ZIP declared size mismatch: $($entry.FullName)" }
            $entryBytes += $entry.Length
            if ($entryBytes -gt 128MB -or $seen.Count -gt 10000) { throw 'ZIP declared size/file cap exceeded' }
        }
        if ($seen.Count -ne $map.Count) { throw 'ZIP missing manifest files' }
        if ($archiveSize -ne $Lock.assembled.size -or $declared -ne $Lock.assembled.expandedSize -or $map.Count -ne $Lock.assembled.fileCount -or $bundle.archiveSha256 -cne $Lock.assembled.archiveSha256) { throw 'Bundle SHA256/size does not match trusted locked assembly' }
        $archiveStream = [IO.File]::OpenRead($archive)
        try { $archiveDigest = Get-RuntimeStreamHash $archiveStream $archiveSize @{bytes=0L} } finally { $archiveStream.Dispose() }
        if ($archiveDigest.sha256 -cne $Lock.assembled.archiveSha256) { throw 'Bundle archive SHA256 mismatch against trusted lock' }
        $suffix = ($Lock.python.version -split '\.')[0..1] -join ''
        foreach ($required in @('python.exe','python3.dll',"python$suffix.dll", "python$suffix.zip", "python$suffix._pth", 'LICENSE.txt','Lib/site-packages/requests/__init__.py','Lib/site-packages/Crypto/__init__.py','Lib/site-packages/lxml/__init__.py','Lib/site-packages/bs4/__init__.py')) {
            if (-not $map.ContainsKey($required) -or $map[$required].size -eq 0) { throw "Bundle missing required implementation: $required" }
        }
        if (-not @($map.Keys | Where-Object {$_ -cmatch '^Lib/site-packages/lxml/etree\..*\.pyd$'}).Count) { throw 'Bundle missing lxml native implementation' }
        $wheelTags = @{}
        foreach ($package in $Lock.packages) {
            $prefix = 'Lib/site-packages/' + $package.name.Replace('-', '_') + '-' + $package.version + '.dist-info/'
            foreach ($required in @('METADATA','WHEEL','RECORD')) { if (-not $map.ContainsKey($prefix + $required)) { throw "Bundle missing dist-info: $prefix$required" } }
            if (-not @($map.Keys | Where-Object { $_.StartsWith($prefix) -and $_ -match '(?i)(license|licence|copying)' }).Count) { throw "Bundle missing package license: $($package.name)" }
            $wheelTags[$prefix+'WHEEL'] = ($package.filename -replace '^.*?-\d+(?:\.\d+)*-','') -replace '\.whl$',''
        }
        $budget = @{bytes=0L}
        foreach ($entry in $zip.Entries) {
            $stream = $entry.Open()
            try { $result = Get-RuntimeStreamHash $stream $entry.Length $budget } finally { $stream.Dispose() }
            if ($result.sha256 -cne $map[$entry.FullName].sha256) { throw "ZIP file SHA256 mismatch: $($entry.FullName)" }
            if ($entry.FullName -ceq 'python.exe' -or $entry.FullName.EndsWith('.dll',[StringComparison]::Ordinal) -or $entry.FullName.EndsWith('.pyd',[StringComparison]::Ordinal)) { Assert-RuntimePeHeader $result.head $entry.FullName }
            if ($entry.FullName -ceq "python$suffix._pth" -and [Text.Encoding]::UTF8.GetString($result.head) -cne "python$suffix.zip`n.`nLib/site-packages`nimport site`n") { throw 'Invalid locked ._pth configuration' }
            if ($wheelTags.ContainsKey($entry.FullName) -and [Text.Encoding]::UTF8.GetString($result.head) -cnotmatch ('(?m)^Tag: '+[regex]::Escape($wheelTags[$entry.FullName])+'\r?$')) { throw "Invalid locked wheel ABI tag: $($entry.FullName)" }
        }
    } finally { $zip.Dispose() }
    return $bundle
}
function Build-PythonRuntime([string]$Output, [string]$Cache, [string]$LockPath, [switch]$Offline, [switch]$ValidateOnly) {
    if (-not $IsWindows) { throw 'Windows x64 native build required' }
    $repo = Split-Path -Parent $PSScriptRoot
    $Output = Assert-RuntimeDirectory $Output $repo
    $Cache = Assert-RuntimeDirectory $Cache $repo
    $lock = Read-RuntimeLock $LockPath
    if (Test-Path -LiteralPath $Output) {
        if (@(Get-ChildItem -LiteralPath $Output -Force).Count -gt 0) {
            $bundle = Test-PythonRuntimeBundle $Output $lock
            Write-Host "Validated existing bundle: $Output sha256=$($bundle.archiveSha256)"
            return
        }
    }
    if ($ValidateOnly) { throw 'Python bundle missing; run scripts/prepare_python_runtime.ps1 before building Windows' }
    New-Item -ItemType Directory -Path $Cache -Force | Out-Null
    $script:RuntimeRequests = 0
    $artifacts = @{}
    foreach ($artifact in @($lock.python) + @($lock.packages)) { $artifacts[$artifact.filename] = Get-RuntimeArtifact $artifact $Cache -Offline:$Offline }
    $work = Assert-RuntimeDirectory (Join-Path $repo ('.local/python-runtime/build-' + [guid]::NewGuid().ToString('N'))) $repo
    $stage = Join-Path $work 'expanded'; New-Item -ItemType Directory -Path $stage | Out-Null
    $budget = @{files=0;bytes=0}
    Expand-RuntimeArchive $artifacts[$lock.python.filename] $stage $budget
    $site = Join-Path $stage 'Lib/site-packages'; New-Item -ItemType Directory -Path $site -Force | Out-Null
    foreach ($package in $lock.packages) { Expand-RuntimeArchive $artifacts[$package.filename] $site $budget }
    $suffix = ($lock.python.version -split '\.')[0..1] -join ''
    $pth = Join-Path $stage "python$suffix._pth"
    [IO.File]::WriteAllText($pth, "python$suffix.zip`n.`nLib/site-packages`nimport site`n", [Text.UTF8Encoding]::new($false))
    Invoke-RuntimeProbe $stage $lock
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\','/');size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    if ($files.Count -gt 10000 -or ($files | Measure-Object size -Sum).Sum -gt 128MB) { throw 'Final expanded runtime exceeds cap' }
    $ready = Join-Path $work 'bundle'; New-Item -ItemType Directory -Path $ready | Out-Null
    $archive = Join-Path $ready 'python-runtime.zip'
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $entry = $zip.CreateEntry($file.path, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2020,1,1,0,0,0,[timespan]::Zero)
            $source = [IO.File]::OpenRead((Join-Path $stage $file.path)); $target = $entry.Open()
            try { $source.CopyTo($target) } finally { $source.Dispose(); $target.Dispose() }
        }
    } finally { $zip.Dispose() }
    $bundle = [ordered]@{
        schemaVersion=1;pythonVersion=$lock.python.version;platform='windows-x64';archive='python-runtime.zip'
        archiveSha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        probeModules=@('requests','Crypto','lxml','bs4')
        packages=@($lock.packages | Sort-Object name | ForEach-Object { [ordered]@{name=$_.name;version=$_.version} })
        files=$files
    }
    [IO.File]::WriteAllText((Join-Path $ready 'bundle.json'), ($bundle | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
    Test-PythonRuntimeBundle $ready $lock | Out-Null
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
    if (@(Get-ChildItem -LiteralPath $Output -Force).Count) { throw 'Refusing to overwrite populated output' }
    Copy-Item -LiteralPath $archive,(Join-Path $ready 'bundle.json') -Destination $Output
    Write-Host "Built runtime: $Output; sha256=$($bundle.archiveSha256); ZIP=$((Get-Item $archive).Length) bytes; expanded=$(($files | Measure-Object size -Sum).Sum) bytes; files=$($files.Count); HTTP=$script:RuntimeRequests"
}

if ($MyInvocation.InvocationName -ne '.') {
    $repo = Split-Path -Parent $PSScriptRoot
    if (-not $OutputDir) { $OutputDir = Join-Path $repo 'runtime/python' }
    if (-not $CacheDir) { $CacheDir = Join-Path $repo '.local/python-runtime/cache' }
    if (-not $LockFile) { $LockFile = Join-Path $PSScriptRoot 'python-runtime.lock.json' }
    Build-PythonRuntime $OutputDir $CacheDir $LockFile -Offline:$Offline -ValidateOnly:$ValidateOnly
}
