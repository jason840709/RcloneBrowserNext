param([switch]$HelperOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RbnRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RbnRoot
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This build targets x64 Windows.' }
$RbnCache = Join-Path $RbnRoot '.build-cache/compat'
$RbnRuntime = Join-Path $RbnCache 'runtime'
New-Item -ItemType Directory -Force -Path $RbnRuntime, (Join-Path $RbnCache 'swift-module-cache') | Out-Null
$RbnSwift = (Get-Command swiftc.exe -ErrorAction Stop).Source
$RbnCl = (Get-Command cl.exe -ErrorAction Stop).Source
if (-not (Test-Path Env:SDKROOT)) { throw 'The Windows Swift SDKROOT is not configured.' }
# swiftc reads SDKROOT, but its Clang imports also need the SDK module path.
# Keep each path as one argument, including installations under Program Files.
$RbnSwiftSdkArgs = @('-sdk', $env:SDKROOT, '-I', (Join-Path $env:SDKROOT 'usr/lib/swift'),
    '-L', (Join-Path $env:SDKROOT 'usr/lib/swift/windows'))
$env:CARGO_HOME = Join-Path $RbnCache 'cargo'
$env:CARGO_TARGET_DIR = Join-Path $RbnCache 'target'
$env:npm_config_cache = Join-Path $RbnCache 'npm'
$env:XDG_CACHE_HOME = Join-Path $RbnCache 'xdg'
$RbnTarget = (& $RbnSwift -print-target-info | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $RbnTarget.target.triple -notmatch '^x86_64-.*-windows-msvc$') {
    throw 'Use the x64 Windows Swift toolchain for this installer.'
}
if ((Test-Path Env:VSCMD_ARG_TGT_ARCH) -and $env:VSCMD_ARG_TGT_ARCH -notin @('x64','amd64')) {
    throw 'Open the x64 MSVC developer environment before building.'
}
if (-not $HelperOnly) {
    Get-Command cargo.exe -ErrorAction Stop | Out-Null
    $RbnRustInfo = @(& rustc.exe -vV)
    if ($LASTEXITCODE -ne 0 -or -not ($RbnRustInfo -match '^host: x86_64-pc-windows-msvc$')) {
        throw 'Use the x86_64-pc-windows-msvc Rust toolchain for this installer.'
    }
    if ((Test-Path Env:CARGO_BUILD_TARGET) -and $env:CARGO_BUILD_TARGET -ne 'x86_64-pc-windows-msvc') {
        throw 'CARGO_BUILD_TARGET must be x86_64-pc-windows-msvc or unset.'
    }
}

python Scripts/prepare-compat.py
if ($LASTEXITCODE -ne 0) { throw 'Compatibility resource preparation failed.' }
$RbnLauncher = Join-Path $RbnRuntime 'rbn-process-launcher.exe'
$RbnObject = Join-Path $RbnCache 'WindowsRcloneLauncher.obj'
& $RbnCl /nologo /O2 /MT /DUNICODE /D_UNICODE (Join-Path $RbnRoot 'Scripts/native/WindowsRcloneLauncher.c') "/Fe:$RbnLauncher" "/Fo:$RbnObject" /link user32.lib
if ($LASTEXITCODE -ne 0) { throw 'The rclone process launcher did not compile.' }
$RbnSources = @(Get-ChildItem -Path (Join-Path $RbnRoot 'Sources/Core/*.swift') -File | Sort-Object Name | ForEach-Object FullName)
$RbnSources += Join-Path $RbnRoot 'Sources/Compat/CompatMain.swift'
$RbnSources += Join-Path $RbnRoot 'Sources/Compat/WindowsLocalFileSystem.swift'
$RbnSwiftArgs = $RbnSwiftSdkArgs + @('-swift-version','5','-O','-module-cache-path',(Join-Path $RbnCache 'swift-module-cache')) + $RbnSources + @('-o',(Join-Path $RbnRuntime 'rbn-engine.exe'))
& $RbnSwift @RbnSwiftArgs
if ($LASTEXITCODE -ne 0) { throw 'The shared Swift engine did not compile.' }

# Resolve actual PE imports, including transitive Swift/Foundation dependencies.
# Only redistributable runtime DLLs are copied; SDKs and compilers stay in CI.
$RbnRoots = [Collections.Generic.List[string]]::new()
foreach ($RbnPart in ($env:PATH -split ';')) { if ($RbnPart -and (Test-Path -LiteralPath $RbnPart -PathType Container)) { $RbnRoots.Add($RbnPart) } }
foreach ($RbnPart in $RbnTarget.paths.runtimeLibraryPaths) { if (Test-Path -LiteralPath $RbnPart) { $RbnRoots.Add($RbnPart) } }
$RbnRoots.Add((Split-Path -Parent $RbnSwift))
$RbnFallbackRoots = @((Join-Path $env:ProgramFiles 'Swift'), (Join-Path $env:LOCALAPPDATA 'Programs/Swift'))
if (Test-Path Env:SDKROOT) { $RbnFallbackRoots += $env:SDKROOT }
$RbnDllIndex = @{}
foreach ($RbnDir in $RbnRoots) {
    Get-ChildItem -LiteralPath $RbnDir -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $RbnKey = $_.Name.ToLowerInvariant(); if (-not $RbnDllIndex.ContainsKey($RbnKey)) { $RbnDllIndex[$RbnKey] = $_.FullName }
    }
}
foreach ($RbnDir in $RbnFallbackRoots) {
    if (Test-Path -LiteralPath $RbnDir) {
        Get-ChildItem -LiteralPath $RbnDir -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $RbnKey = $_.Name.ToLowerInvariant(); if (-not $RbnDllIndex.ContainsKey($RbnKey)) { $RbnDllIndex[$RbnKey] = $_.FullName }
        }
    }
}
$RbnQueue = [Collections.Generic.Queue[string]]::new()
$RbnQueue.Enqueue((Join-Path $RbnRuntime 'rbn-engine.exe'))
$RbnCopied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$RbnSystem = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$RbnSystemDir = [Environment]::SystemDirectory
while ($RbnQueue.Count -gt 0) {
    $RbnBinary = $RbnQueue.Dequeue()
    $RbnImports = & dumpbin.exe /nologo /dependents $RbnBinary
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect PE imports: $RbnBinary" }
    foreach ($RbnLine in $RbnImports) {
        if ($RbnLine -notmatch '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { continue }
        $RbnName = $Matches[1]; $RbnKey = $RbnName.ToLowerInvariant()
        if ($RbnCopied.Contains($RbnName) -or $RbnSystem.Contains($RbnName)) { continue }
        $RbnIsVCRuntime = $RbnName -match '^(vcruntime|msvcp|concrt)'
        if (($RbnName -match '^(api-ms-|ext-ms-)') -or ((Test-Path -LiteralPath (Join-Path $RbnSystemDir $RbnName)) -and -not $RbnIsVCRuntime)) {
            [void]$RbnSystem.Add($RbnName); continue
        }
        if ($RbnDllIndex.ContainsKey($RbnKey)) { $RbnSource = $RbnDllIndex[$RbnKey] }
        elseif ($RbnIsVCRuntime -and (Test-Path -LiteralPath (Join-Path $RbnSystemDir $RbnName))) { $RbnSource = Join-Path $RbnSystemDir $RbnName }
        else { throw "Required runtime DLL not found: $RbnName" }
        $RbnDestination = Join-Path $RbnRuntime $RbnName
        Copy-Item -LiteralPath $RbnSource -Destination $RbnDestination -Force
        [void]$RbnCopied.Add($RbnName); $RbnQueue.Enqueue($RbnDestination)
    }
}
$RbnLibraries = @(Get-ChildItem -LiteralPath $RbnRuntime -Filter '*.dll' | Sort-Object Name | ForEach-Object {
    @{ name=$_.Name; bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
@{ swift=((& $RbnSwift --version) -join "`n"); libraries=$RbnLibraries; systemLibraries=@($RbnSystem | Sort-Object) } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RbnRuntime 'runtime-manifest.json') -Encoding UTF8
if ($HelperOnly) { Write-Host 'Windows helper and runtime are ready.'; exit 0 }

Get-Command cargo.exe -ErrorAction Stop | Out-Null
Get-Command npm.cmd -ErrorAction Stop | Out-Null
$RbnCli = Join-Path $RbnCache 'cli'
New-Item -ItemType Directory -Force -Path $RbnCli | Out-Null
Copy-Item -LiteralPath 'Compat/cli/package.json','Compat/cli/package-lock.json' -Destination $RbnCli -Force
& npm.cmd ci --prefix $RbnCli --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'The pinned Tauri CLI could not be installed into the project.' }
Push-Location -LiteralPath (Join-Path $RbnRoot 'Compat/desktop')
try {
    & cargo.exe test --locked
    if ($LASTEXITCODE -ne 0) { throw 'The native host tests failed.' }
    python (Join-Path $RbnRoot 'Scripts/collect-compat-notices.py')
    if ($LASTEXITCODE -ne 0) { throw 'Runtime dependency notices could not be collected.' }
    & (Join-Path $RbnCli 'node_modules/.bin/tauri.cmd') build --bundles nsis --ci
    if ($LASTEXITCODE -ne 0) { throw 'The Windows installer build failed.' }
} finally { Pop-Location }
python Scripts/windows/package-candidate.py --cache $RbnCache
if ($LASTEXITCODE -ne 0) { throw 'The Windows candidate package could not be prepared.' }
