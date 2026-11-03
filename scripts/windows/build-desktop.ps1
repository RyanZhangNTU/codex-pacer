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
    foreach ($taskProduct in @('PacerWindowsBridge','PacerInstallerHooks')) {
        swift build --build-system native @taskSwiftFlags --package-path $taskReceipt.source --scratch-path $taskReceipt.scratch --configuration $Configuration.ToLowerInvariant() --product $taskProduct
        if ($LASTEXITCODE -ne 0) { throw ('Windows adapter build failed: ' + $taskProduct) }
    }
    $taskVersion = Get-PacerVersion
    dotnet build windows/Desktop/Pacer.Windows.csproj --configuration $Configuration -warnaserror "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'Windows desktop build failed.' }
    $taskBinary = Join-Path $taskReceipt.scratch ('x86_64-unknown-windows-msvc/' + $Configuration.ToLowerInvariant())
    $taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows')
    $taskDestination = Join-Path $taskDesktop 'Engine'
    New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
    foreach ($taskFile in @('PacerEngine.exe','PacerWindowsBridge.dll','PacerInstallerHooks.exe')) {
        Copy-Item -LiteralPath (Join-Path $taskBinary $taskFile) -Destination $taskDestination -Force
    }
    $taskPython = & (Join-Path $PSScriptRoot 'setup-claude-python.ps1')
    $taskPythonTarget = Join-Path $taskDestination 'Python'
    New-Item -ItemType Directory -Path $taskPythonTarget -Force | Out-Null
    Get-ChildItem -LiteralPath $taskPython -File | Copy-Item -Destination $taskPythonTarget -Force
    foreach ($taskBundle in Get-ChildItem -LiteralPath $taskBinary -Directory -Filter '*.resources') {
        foreach ($taskParent in @($taskDestination, $taskDesktop)) {
            $taskTarget = Join-Path $taskParent $taskBundle.Name
            New-Item -ItemType Directory -Path $taskTarget -Force | Out-Null
            Get-ChildItem -LiteralPath $taskBundle.FullName | Copy-Item -Destination $taskTarget -Recurse -Force
        }
    }
    if (!$taskRuntime) { throw 'The pinned Swift runtime is required.' }
    Get-ChildItem -LiteralPath (Join-Path $taskRuntime.FullName 'usr/bin') -File -Filter '*.dll' | Copy-Item -Destination $taskDestination -Force
    & (Join-Path $PSScriptRoot 'build-maintenance.ps1') -Configuration $Configuration
} finally { Pop-Location }
