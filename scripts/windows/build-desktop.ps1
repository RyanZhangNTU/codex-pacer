param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug', [switch]$SkipEngine)
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
Push-Location $taskRoot
try {
    python -S scripts/windows/build-localization.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Shared localization differs.' }
    python -S scripts/windows/build-shell-resources.py --check
    if ($LASTEXITCODE -ne 0) { throw 'WPF resources differ.' }
    if (!$SkipEngine) { & (Join-Path $PSScriptRoot 'build-engine.ps1') -Configuration $Configuration.ToLowerInvariant() }
    $taskReceipt = Get-Content output/windows/engine-location.json -Raw | ConvertFrom-Json
    swift build --build-system native @taskSwiftFlags --package-path $taskReceipt.source --scratch-path $taskReceipt.scratch --configuration $Configuration.ToLowerInvariant() --product PacerWindowsBridge
    if ($LASTEXITCODE -ne 0) { throw 'Windows UI adapter build failed.' }
    $taskVersion = Get-PacerVersion
    dotnet build windows/Desktop/Pacer.Windows.csproj --configuration $Configuration -warnaserror "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'Windows desktop build failed.' }
    $taskBinary = Join-Path $taskReceipt.scratch ('x86_64-unknown-windows-msvc/' + $Configuration.ToLowerInvariant())
    $taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows')
    $taskDestination = Join-Path $taskDesktop 'Engine'
    New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
    foreach ($taskFile in @('PacerEngine.exe','PacerWindowsBridge.dll')) {
        Copy-Item -LiteralPath (Join-Path $taskBinary $taskFile) -Destination $taskDestination -Force
    }
    foreach ($taskBundle in Get-ChildItem -LiteralPath $taskBinary -Directory -Filter '*.resources') {
        foreach ($taskParent in @($taskDestination, $taskDesktop)) {
            $taskTarget = Join-Path $taskParent $taskBundle.Name
            New-Item -ItemType Directory -Path $taskTarget -Force | Out-Null
            Get-ChildItem -LiteralPath $taskBundle.FullName | Copy-Item -Destination $taskTarget -Recurse -Force
        }
    }
    if (!$taskRuntime) { throw 'The pinned Swift runtime is required.' }
    Get-ChildItem -LiteralPath (Join-Path $taskRuntime.FullName 'usr/bin') -File -Filter '*.dll' | Copy-Item -Destination $taskDestination -Force
} finally { Pop-Location }
