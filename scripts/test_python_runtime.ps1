[CmdletBinding()]
param([string]$CacheDir = '', [switch]$Integration, [string]$CmakeExecutable = '', [switch]$Review)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $PSScriptRoot 'prepare_python_runtime.ps1'
if (-not (Test-Path -LiteralPath $builder)) { throw 'FAIL: runtime builder feature is missing' }
. $builder -CacheDir $CacheDir
$testRoot = Join-Path $repo ('.local/python-runtime-tests/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
function Check([string]$name, [scriptblock]$body) {
    & $body
    $script:passed++
    Write-Host "PASS $name"
}
function Must-Fail([scriptblock]$body, [string]$pattern) {
    $caught = $null
    try { & $body } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $caught -notmatch $pattern) { throw "Expected failure matching $pattern; got $caught" }
}
Check 'reject relative traversal and Windows ambiguous paths' {
    foreach ($path in @('../user.json','C:/python.exe','/python.exe','a\b','a/../b','a//b','a:b','CON','a./b','a /b')) {
        Must-Fail { Assert-RuntimeRelativePath $path } 'Unsafe'
    }
    Assert-RuntimeRelativePath 'Lib/site-packages/requests/__init__.py'
}
Check 'reject repository root, user paths and reparse ancestors' {
    Must-Fail { Assert-RuntimeDirectory $repo $repo } 'Unsafe'
    Must-Fail { Assert-RuntimeDirectory $env:USERPROFILE $repo } 'Unsafe'
    $target = Join-Path $testRoot 'target'; New-Item -ItemType Directory $target | Out-Null
    $link = Join-Path $testRoot 'link'; New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Must-Fail { Assert-RuntimeDirectory (Join-Path $link 'out') $repo } 'reparse'
}
Check 'cached bytes must match lock, even offline' {
    $cache = Join-Path $testRoot 'cache'; New-Item -ItemType Directory $cache | Out-Null
    [IO.File]::WriteAllText((Join-Path $cache 'sample.whl'), 'abc', [Text.UTF8Encoding]::new($false))
    $artifact = [pscustomobject]@{filename='sample.whl'; sha256='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'; url='https://files.pythonhosted.org/sample.whl'; size=3}
    $got = Get-RuntimeArtifact $artifact $cache -Offline
    if ((Get-Content $got -Raw) -ne 'abc') { throw 'Wrong cached bytes' }
    $artifact.sha256 = '0' * 64
    Must-Fail { Get-RuntimeArtifact $artifact $cache -Offline } 'SHA256'
    $artifact.filename = 'missing.whl'
    Must-Fail { Get-RuntimeArtifact $artifact $cache -Offline } 'Offline cache miss'
}
Check 'lock refuses missing wheel and incompatible platform wheel' {
    $lock = Get-Content (Join-Path $PSScriptRoot 'python-runtime.lock.json') -Raw | ConvertFrom-Json
    $lock.packages = @($lock.packages | Where-Object name -ne 'requests')
    $path = Join-Path $testRoot 'missing.lock.json'; $lock | ConvertTo-Json -Depth 12 | Set-Content $path
    Must-Fail { Read-RuntimeLock $path } 'closure'
    $lock = Get-Content (Join-Path $PSScriptRoot 'python-runtime.lock.json') -Raw | ConvertFrom-Json
    $lock.packages[0].filename = 'requests-2.34.2-cp312-cp312-win_amd64.whl'
    $lock | ConvertTo-Json -Depth 12 | Set-Content $path
    Must-Fail { Read-RuntimeLock $path } 'wheel'
}
Check 'ZIP traversal rejected before any extraction' {
    $zipPath = Join-Path $testRoot 'unsafe.zip'
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try { $entry = $zip.CreateEntry('../user-config.json'); $s = $entry.Open(); $s.WriteByte(1); $s.Dispose() } finally { $zip.Dispose() }
    $dest = Join-Path $testRoot 'extract'; New-Item -ItemType Directory $dest | Out-Null
    $budget = @{files=0;bytes=0}
    Must-Fail { Expand-RuntimeArchive $zipPath $dest $budget } 'Unsafe'
    if (Test-Path (Join-Path $testRoot 'user-config.json')) { throw 'Escaped extraction directory' }
}
Check 'packaging rejects missing Python without producing a degraded zip' {
    $fixture = Join-Path $testRoot 'package-fixture'; New-Item -ItemType Directory $fixture | Out-Null
    foreach ($relative in @('sidecars/spider-host-python/host.py','sidecars/spider-host-python/webhtv_ipc.py','sidecars/spider-host-python/webhtv_catvod.py','sidecars/spider-host-python/base/__init__.py','sidecars/spider-host-python/base/spider.py','sidecars/spider-host-js/host.js','sidecars/spider-host-js/sandbox_worker.js','sidecars/spider-host-js/esm_shim.js','sidecars/spider-host-js/tvbox_globals.js','sidecars/spider-host-js/package.json','sidecars/spider-host-jvm/host.jar','node/node.exe','build/webhtv_pc.exe')) {
        $path = Join-Path $fixture $relative; New-Item -ItemType Directory (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
    foreach ($relative in @('sidecars/spider-host-js/node_modules','sidecars/spider-host-jvm/lib')) { New-Item -ItemType Directory (Join-Path $fixture $relative) -Force | Out-Null }
    $script:packageFixture = $fixture
    $out = Join-Path $fixture 'dist'
    Must-Fail { & (Join-Path $PSScriptRoot 'package_windows.ps1') -RepoRoot $fixture -BuildDir (Join-Path $fixture 'build') -OutputDir $out -NodeRuntimeDir (Join-Path $fixture 'node') -Version 0.1.0 -Commit ('0' * 40) } 'Python bundle missing'
    if (Test-Path $out) { throw 'Missing Python changed output directory' }
}
Check 'packaging preserves existing output and sidecar mandatory checks' {
    $fixture = $script:packageFixture
    $out = Join-Path $fixture 'protected-output'; New-Item -ItemType Directory $out | Out-Null
    $sentinel = Join-Path $out 'user-config.json'; [IO.File]::WriteAllText($sentinel, 'do-not-delete')
    Must-Fail { & (Join-Path $PSScriptRoot 'package_windows.ps1') -RepoRoot $fixture -BuildDir (Join-Path $fixture 'build') -OutputDir $out -NodeRuntimeDir (Join-Path $fixture 'node') -Version 0.1.0 -Commit ('0' * 40) } '输出目录必须'
    if ((Get-Content $sentinel -Raw) -ne 'do-not-delete') { throw 'Packaging changed existing output' }
    $emptyRepo = Join-Path $testRoot 'no-sidecars'; New-Item -ItemType Directory (Join-Path $emptyRepo 'build') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $emptyRepo 'build/webhtv_pc.exe'), 'fixture')
    Must-Fail { & (Join-Path $PSScriptRoot 'package_windows.ps1') -RepoRoot $emptyRepo -BuildDir (Join-Path $emptyRepo 'build') -OutputDir (Join-Path $emptyRepo 'dist') -Version 0.1.0 -Commit ('0' * 40) } '缺少 sidecar 宿主文件'
}
if ($Review) {
    $reviewFailures = [Collections.Generic.List[string]]::new()
    $reviewLock = Read-RuntimeLock (Join-Path $PSScriptRoot 'python-runtime.lock.json')
    function Review-Check([string]$name, [scriptblock]$body) {
        try { & $body; $script:passed++; Write-Host "PASS $name" }
        catch { $reviewFailures.Add($name); Write-Host "RED $name : $($_.Exception.Message)" }
    }
    function New-ReviewBundle([string]$name, [scriptblock]$mutateZip, [scriptblock]$mutateManifest) {
        $dir = Join-Path $testRoot $name; New-Item -ItemType Directory $dir | Out-Null
        $archive = Join-Path $dir 'python-runtime.zip'
        Copy-Item -LiteralPath (Join-Path $repo 'runtime/python/python-runtime.zip') -Destination $archive
        $bundle = Get-Content (Join-Path $repo 'runtime/python/bundle.json') -Raw | ConvertFrom-Json
        if ($mutateZip) {
            $z = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Update)
            try { & $mutateZip $z } finally { $z.Dispose() }
            $z = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $bundle.files = @($z.Entries | ForEach-Object {
                    $s = $_.Open(); $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hash = [Convert]::ToHexString($sha.ComputeHash($s)).ToLowerInvariant() } finally { $s.Dispose(); $sha.Dispose() }
                    [pscustomobject]@{path=$_.FullName;size=$_.Length;sha256=$hash}
                })
            } finally { $z.Dispose() }
            $bundle.archiveSha256 = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($mutateManifest) { & $mutateManifest $bundle }
        $bundle | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'bundle.json')
        return $dir
    }
    Review-Check 'F1 self-consistent executable/pth/module replacement rejected against trusted lock' {
        $mutations = @(
            @{name='empty-exe';body={param($z) $z.GetEntry('python.exe').Delete(); $z.CreateEntry('python.exe') | Out-Null}},
            @{name='bad-pth';body={param($z) $z.GetEntry('python314._pth').Delete(); $e=$z.CreateEntry('python314._pth'); $w=[IO.StreamWriter]::new($e.Open()); $w.Write("python314.zip`nimport site`n"); $w.Dispose()}},
            @{name='missing-requests';body={param($z) @($z.Entries | Where-Object {$_.FullName.StartsWith('Lib/site-packages/requests/')}) | ForEach-Object {$_.Delete()}}}
        )
        $missed = @()
        foreach ($m in $mutations) {
            $dir = New-ReviewBundle $m.name $m.body $null
            try { Test-PythonRuntimeBundle $dir $reviewLock | Out-Null; $missed += $m.name } catch { if ($_.Exception.Message -notmatch 'trusted|locked|implementation|pth|ABI') { throw } }
        }
        if ($missed.Count) { throw "Accepted self-consistent attacks: $($missed -join ',')" }
    }
    Review-Check 'F2 strict manifest JSON field types and structures' {
        $mutations = @(
            @{name='string-schema';body={param($b) $b.schemaVersion='1'}},
            @{name='scalar-probes';body={param($b) $b.probeModules='requests,Crypto,lxml,bs4'}},
            @{name='wrong-platform-case';body={param($b) $b.platform='WINDOWS-X64'}},
            @{name='scalar-packages';body={param($b) $b.packages=$b.packages[0]}},
            @{name='string-size';body={param($b) $b.files[0].size=[string]$b.files[0].size}}
        )
        $missed=@()
        foreach($m in $mutations) {
            $dir=New-ReviewBundle $m.name $null $m.body
            try {Test-PythonRuntimeBundle $dir $reviewLock | Out-Null; $missed+=$m.name} catch {if($_.Exception.Message -notmatch 'schema|contract|entry|closure'){throw}}
        }
        if($missed.Count){throw "Accepted wrong JSON types: $($missed -join ',')"}
    }
    Review-Check 'F3 archive and declared-entry gates run before any content read' {
        $dir=Join-Path $testRoot 'oversized-archive'; New-Item -ItemType Directory $dir | Out-Null
        Copy-Item (Join-Path $repo 'runtime/python/bundle.json') (Join-Path $dir 'bundle.json')
        $file=[IO.File]::Open((Join-Path $dir 'python-runtime.zip'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$file.SetLength(128MB+1); Must-Fail {Test-PythonRuntimeBundle $dir $reviewLock} 'archive size cap'} finally {$file.Dispose()}
        $dir=New-ReviewBundle 'entry-size' {param($z) $e=$z.CreateEntry('oversized.bin'); $s=$e.Open(); $s.Write([byte[]]::new(1MB)); $s.Dispose()} {param($b) ($b.files | Where-Object path -eq 'oversized.bin').size=0}
        Must-Fail {Test-PythonRuntimeBundle $dir $reviewLock} 'declared size'
    }
    Review-Check 'F3 actual hash reads stop at declared limit even for forged lengths' {
        $stream=[IO.MemoryStream]::new([byte[]]::new(2MB))
        $budget=@{bytes=0}
        try {
            Must-Fail {Get-RuntimeStreamHash $stream 1024 $budget} 'actual size'
            if($stream.Position -gt 1025){throw "Over-read forged stream: $($stream.Position)"}
        } finally {$stream.Dispose()}
    }
    Review-Check 'F4 Win32 superscript COM LPT devices rejected in every component' {
        $missed=@()
        foreach($path in @('COM¹','COM².txt','LPT³','Lib/site-packages/COM¹.py','a/LPT²/b')) {
            try {Assert-RuntimeRelativePath $path; $missed+=$path} catch {if($_.Exception.Message -notmatch 'Unsafe'){throw}}
        }
        if($missed.Count){throw "Accepted devices: $($missed -join ',')"}
    }
    Review-Check 'F5 execute real release-note step with offline Python and local JVM disclosure' {
        $y=Get-Content (Join-Path $repo '.github/workflows/windows-release.yml') -Raw
        $step=[regex]::Match($y,'(?s)      - name: Prepare release notes.*?        run: \|\r?\n(?<body>.*?)\r?\n      - name: Package portable zip').Groups['body'].Value
        if(-not $step){throw 'Release notes step not found'}
        $step=($step -split "`n" | ForEach-Object {$_ -replace '^          ',''}) -join "`n"
        $step=[regex]::Replace($step,'\$\{\{.*?\}\}','false')
        $old=@{}; foreach($key in @('GITHUB_WORKSPACE','GITHUB_OUTPUT','RAW_NOTES','SIGNED')){$old[$key]=[Environment]::GetEnvironmentVariable($key)}
        $notesRoot=Join-Path $testRoot 'notes'; New-Item -ItemType Directory $notesRoot | Out-Null
        try {
            $env:GITHUB_WORKSPACE=$notesRoot; $env:GITHUB_OUTPUT=Join-Path $notesRoot 'output.txt'; $env:RAW_NOTES='Review fixture'; $env:SIGNED='false'
            & ([scriptblock]::Create($step)) 6>$null
            $body=Get-Content (Join-Path $notesRoot 'build/release-notes.md') -Raw
            if($body -notmatch 'Python 3\.14\.10' -or $body -notmatch '离线' -or $body -notmatch 'JDK 17\+' -or $body -match '需要本机安装 Python'){throw 'Published notes contradict bundled/offline Python'}
        } finally {foreach($key in $old.Keys){[Environment]::SetEnvironmentVariable($key,$old[$key])}}
    }
    Review-Check 'F6 polluted native build rejected without publishing or changing input' {
        $fixture=$script:packageFixture
        $jar=Join-Path $fixture 'review-valid-host.jar'; $z=[IO.Compression.ZipFile]::Open($jar,[IO.Compression.ZipArchiveMode]::Create)
        try {$e=$z.CreateEntry('META-INF/MANIFEST.MF'); $w=[IO.StreamWriter]::new($e.Open()); $w.Write("Manifest-Version: 1.0`r`nClass-Path: lib/sample.jar`r`n`r`n"); $w.Dispose()}finally{$z.Dispose()}
        Copy-Item $jar (Join-Path $fixture 'sidecars/spider-host-jvm/host.jar') -Force
        Copy-Item $jar (Join-Path $fixture 'sidecars/spider-host-jvm/lib/sample.jar') -Force
        $missed=@()
        foreach($pollution in @('user-config.json','userdata/private.json','spiders/private.py','data/flutter_assets/assets/private.db')) {
            $build=Join-Path $fixture ('dirty-build-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $build | Out-Null
            Copy-Item (Join-Path $fixture 'build/webhtv_pc.exe') $build
            $sentinel=Join-Path $build $pollution; New-Item -ItemType Directory (Split-Path -Parent $sentinel) -Force | Out-Null; [IO.File]::WriteAllText($sentinel,'PRIVATE')
            $out=Join-Path $fixture ('dirty-dist-'+[guid]::NewGuid().ToString('N'))
            try { & (Join-Path $PSScriptRoot 'package_windows.ps1') -RepoRoot $fixture -BuildDir $build -OutputDir $out -NodeRuntimeDir (Join-Path $fixture 'node') -PythonRuntimeDir (Join-Path $repo 'runtime/python') -Version 0.1.0 -Commit ('0'*40) 6>$null; $missed+=$pollution } catch {if($_.Exception.Message -notmatch 'Untrusted|Forbidden|不允许'){throw}}
            if((Get-Content $sentinel -Raw) -ne 'PRIVATE'){throw 'Pollution rejection changed input'}
            if(-not ($pollution -in $missed) -and (Test-Path $out)){throw 'Rejected input created output'}
        }
        if($missed.Count){throw "Published user data: $($missed -join ',')"}
    }
    if($reviewFailures.Count){throw "Review RED: $($reviewFailures.Count) cases failed: $($reviewFailures -join '; ')"}
}
if ($Integration) {
    if (-not $CacheDir) { $CacheDir = Join-Path $repo '.local/python-runtime/cache' }
    Check 'real offline build, schema, licenses and isolated native imports' {
        $output = Join-Path $testRoot 'runtime/python'
        $log = @(& $builder -OutputDir $output -CacheDir $CacheDir -Offline 6>&1)
        Write-Host ($log -join "`n")
        if (($log -join "`n") -notmatch 'expanded=\d+ bytes') { throw 'Missing measured expanded runtime size' }
        $bundle = Test-PythonRuntimeBundle $output (Read-RuntimeLock (Join-Path $PSScriptRoot 'python-runtime.lock.json'))
        if ($bundle.files.Count -gt 10000 -or ($bundle.files | Measure-Object size -Sum).Sum -gt 128MB) { throw 'Exceeded expanded budget' }
        if ($bundle.probeModules -join ',' -ne 'requests,Crypto,lxml,bs4') { throw 'Wrong probe contract' }
        if (($bundle.PSObject.Properties.Name | Sort-Object) -join ',' -ne 'archive,archiveSha256,files,packages,platform,probeModules,pythonVersion,schemaVersion') { throw 'Unexpected schema keys' }
        $paths = $bundle.files.path
        if ('LICENSE.txt' -notin $paths -or 'python314._pth' -notin $paths) { throw 'Missing Python license/config' }
        foreach ($package in $bundle.packages) {
            $stem = $package.name.Replace('-', '_') + '-' + $package.version + '.dist-info/'
            if (-not @($paths | Where-Object { $_.StartsWith('Lib/site-packages/' + $stem) -and $_ -match '(?i)licen[sc]e|copying' }).Count) { throw "Missing license: $($package.name)" }
        }
        if (@($paths | Where-Object {$_ -match '(^|/)(bundle.json|__pycache__|spiders|manifests|user-config.json|\.git)(/|$)'}).Count) { throw 'Unexpected source/config content' }
        $nativeDir = Join-Path $testRoot 'native'; New-Item -ItemType Directory $nativeDir | Out-Null
        Expand-RuntimeArchive (Join-Path $output 'python-runtime.zip') $nativeDir @{files=0;bytes=0}
        Invoke-RuntimeProbe $nativeDir (Read-RuntimeLock (Join-Path $PSScriptRoot 'python-runtime.lock.json'))
        $fixture = $script:packageFixture
        $jar = Join-Path $fixture 'valid-host.jar'
        $jvm = [IO.Compression.ZipFile]::Open($jar, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $jvm.CreateEntry('META-INF/MANIFEST.MF'); $writer = [IO.StreamWriter]::new($entry.Open())
            $writer.Write("Manifest-Version: 1.0`r`nClass-Path: lib/sample.jar`r`n`r`n"); $writer.Dispose()
        } finally { $jvm.Dispose() }
        Copy-Item -LiteralPath $jar -Destination (Join-Path $fixture 'sidecars/spider-host-jvm/host.jar') -Force
        Copy-Item -LiteralPath $jar -Destination (Join-Path $fixture 'sidecars/spider-host-jvm/lib/sample.jar')
        foreach ($relative in @('flutter_windows.dll','webhtv_pc.pdb','native_assets.json','data/icudtl.dat','data/flutter_assets/FontManifest.json','data/flutter_assets/assets/public.json')) {
            $path=Join-Path $fixture ('build/'+$relative); New-Item -ItemType Directory (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path,'legitimate-build-fixture')
        }
        & (Join-Path $PSScriptRoot 'package_windows.ps1') -RepoRoot $fixture -BuildDir (Join-Path $fixture 'build') -OutputDir (Join-Path $fixture 'dist') -NodeRuntimeDir (Join-Path $fixture 'node') -PythonRuntimeDir $output -Version 0.1.0 -Commit ('0' * 40)
        $info = Get-Content (Join-Path $fixture 'dist/release-info.json') -Raw | ConvertFrom-Json
        if (($info.runtimes.bundled.id -join ',') -ne 'node,python' -or ($info.runtimes.requiresLocal -join ',') -ne 'JDK 17+') { throw 'Release metadata does not reflect bundled Python' }
        $release = Get-ChildItem (Join-Path $fixture 'dist') -Filter '*.zip' | Select-Object -First 1
        $zip = [IO.Compression.ZipFile]::OpenRead($release.FullName)
        try {
            foreach ($relative in @('runtime/python/python-runtime.zip','runtime/python/bundle.json','runtime/node/node.exe','sidecars/spider-host-python/host.py','sidecars/spider-host-js/host.js','sidecars/spider-host-jvm/host.jar')) {
                if (-not @($zip.Entries | Where-Object {$_.FullName.EndsWith('/' + $relative)}).Count) { throw "Package omitted $relative" }
            }
        } finally { $zip.Dispose() }
        if ($CmakeExecutable) {
            $cmakeRepo = Join-Path $testRoot 'cmake-fixture'
            $cmakeSource = Join-Path $cmakeRepo 'apps/desktop-flutter/windows'
            New-Item -ItemType Directory $cmakeSource -Force | Out-Null
            New-Item -ItemType Directory (Join-Path $cmakeRepo 'scripts') | Out-Null
            Copy-Item -LiteralPath $builder,(Join-Path $PSScriptRoot 'python-runtime.lock.json') -Destination (Join-Path $cmakeRepo 'scripts')
            $source = Get-Content (Join-Path $repo 'apps/desktop-flutter/windows/CMakeLists.txt') -Raw
            $start = $source.IndexOf('# Python is prepared explicitly'); $end = $source.IndexOf('# === Installation ===', $start)
            $install = $source.LastIndexOf('install(FILES')
            $fixtureSource = "cmake_minimum_required(VERSION 3.14)`nproject(python_bundle_probe NONE)`nset(BINARY_NAME webhtv_pc)`nadd_custom_target(webhtv_pc)`n" + $source.Substring($start,$end-$start) + $source.Substring($install)
            Set-Content (Join-Path $cmakeSource 'CMakeLists.txt') $fixtureSource
            $build = Join-Path $cmakeRepo 'build'; $cmakeLog = Join-Path $cmakeRepo 'cmake.log'
            $installDir = Join-Path $cmakeRepo 'installed'
            $prefixArg = '-DCMAKE_INSTALL_PREFIX=' + $installDir
            & $CmakeExecutable -S $cmakeSource -B $build -G 'Visual Studio 17 2022' -A x64 $prefixArg *> $cmakeLog
            if ($LASTEXITCODE -eq 0 -or (Get-Content $cmakeLog -Raw) -notmatch 'Python runtime missing or invalid') { throw 'CMake accepted missing Python runtime' }
            $runtime = Join-Path $cmakeRepo 'runtime/python'; New-Item -ItemType Directory $runtime -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $output 'bundle.json'),(Join-Path $output 'python-runtime.zip') -Destination $runtime
            & $CmakeExecutable -S $cmakeSource -B $build -G 'Visual Studio 17 2022' -A x64 $prefixArg *> $cmakeLog
            if ($LASTEXITCODE -ne 0) { Get-Content $cmakeLog -Tail 15; throw 'CMake valid runtime configure failed' }
            foreach ($configuration in @('Debug','Release')) {
                & $CmakeExecutable --build $build --config $configuration --target verify_python_runtime *> $cmakeLog
                if ($LASTEXITCODE -ne 0) { Get-Content $cmakeLog -Tail 15; throw "CMake $configuration validation target failed" }
                & $CmakeExecutable --install $build --config $configuration --prefix $installDir *> $cmakeLog
                if ($LASTEXITCODE -ne 0) { Get-Content $cmakeLog -Tail 15; throw "CMake $configuration install failed" }
                Test-PythonRuntimeBundle (Join-Path $installDir 'runtime/python') (Read-RuntimeLock (Join-Path $PSScriptRoot 'python-runtime.lock.json')) | Out-Null
            }
            Write-Host 'PASS actual CMake fragment: missing bundle fails; Debug/Release validate and install exact bundle'
        }
        $manifest = Join-Path $output 'bundle.json'
        $bundle.archiveSha256 = '0' * 64; $bundle | ConvertTo-Json -Depth 10 | Set-Content $manifest
        Must-Fail { Test-PythonRuntimeBundle $output (Read-RuntimeLock (Join-Path $PSScriptRoot 'python-runtime.lock.json')) } 'SHA256'
        Write-Host "Evidence retained: $testRoot"
    }
}
Write-Host "GREEN: $passed tests passed"
