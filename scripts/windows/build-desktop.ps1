param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug', [switch]$SkipEngine, [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }),
    # CI: also copy the compiled engine and adapters here, for build-engine.ps1 -Products in a later run.
    [string]$SaveEngineProducts)
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
Push-Location $taskRoot
try {
    python -S scripts/windows/build-localization.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Shared localization differs.' }
    python -S scripts/windows/build-shell-resources.py --check
    if ($LASTEXITCODE -ne 0) { throw 'WPF resources differ.' }
    if (!$SkipEngine) { & (Join-Path $PSScriptRoot 'build-engine.ps1') -Configuration $Configuration.ToLowerInvariant() -Architecture $Architecture }
    $taskReceipt = Get-Content (Join-Path 'output/windows' $taskArchitecture.Receipt) -Raw | ConvertFrom-Json
    if ($taskReceipt.architecture -and $taskReceipt.architecture -ne $Architecture) { throw 'The engine receipt architecture differs from the desktop target.' }
    $taskBinary = Join-Path $taskReceipt.scratch ($taskArchitecture.Triple + '/' + $Configuration.ToLowerInvariant())
    # Prebuilt engine products already hold both adapters of the same source snapshot.
    if (!$taskReceipt.prebuilt) {
        foreach ($taskProduct in @('PacerWindowsBridge','PacerInstallerHooks')) {
            swift build --build-system native @taskSwiftFlags @taskSwiftTargetFlags --package-path $taskReceipt.source --scratch-path $taskReceipt.scratch --configuration $Configuration.ToLowerInvariant() --product $taskProduct
            if ($LASTEXITCODE -ne 0) { throw ('Windows adapter build failed: ' + $taskProduct) }
        }
        if ($SaveEngineProducts) {
            New-Item -ItemType Directory -Path $SaveEngineProducts -Force | Out-Null
            foreach ($taskFile in @('PacerEngine.exe','PacerWindowsBridge.dll','PacerInstallerHooks.exe')) {
                Copy-Item -LiteralPath (Join-Path $taskBinary $taskFile) -Destination $SaveEngineProducts -Force
            }
            Get-ChildItem -LiteralPath $taskBinary -Directory -Filter '*.resources' | Copy-Item -Destination $SaveEngineProducts -Recurse -Force
            @{source = (Split-Path $taskReceipt.source -Leaf); configuration = $Configuration.ToLowerInvariant(); architecture = $Architecture} | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $SaveEngineProducts 'products.json') -Encoding utf8
        }
    }
    $taskVersion = Get-PacerVersion
    dotnet build windows/Desktop/Pacer.Windows.csproj --configuration $Configuration -warnaserror "-p:PacerArchitecture=$Architecture" "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'Windows desktop build failed.' }
    $taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows' + $taskArchitecture.DesktopSuffix)
    $taskDestination = Join-Path $taskDesktop 'Engine'
    New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
    foreach ($taskFile in @('PacerEngine.exe','PacerWindowsBridge.dll','PacerInstallerHooks.exe')) {
        Copy-Item -LiteralPath (Join-Path $taskBinary $taskFile) -Destination $taskDestination -Force
    }
    $taskPython = & (Join-Path $PSScriptRoot 'setup-claude-python.ps1') -Architecture $Architecture
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
    & (Join-Path $PSScriptRoot 'build-maintenance.ps1') -Configuration $Configuration -Architecture $Architecture
} finally { Pop-Location }
