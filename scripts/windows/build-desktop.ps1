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
    if ($taskReceipt.configuration -ne $Configuration) { throw 'The engine receipt configuration differs from the desktop target.' }
    $taskBinary = if ($taskReceipt.binary) { $taskReceipt.binary } else { Join-Path $taskReceipt.scratch ($taskArchitecture.Triple + '/' + $Configuration.ToLowerInvariant()) }
    if (!$taskReceipt.adapters -and !$taskReceipt.prebuilt) {
        & (Join-Path $PSScriptRoot 'build-adapters.ps1') -SourcePath $taskReceipt.source -ScratchPath $taskReceipt.scratch -Configuration $Configuration.ToLowerInvariant()
    }
    if ($SaveEngineProducts) {
        python -S scripts/windows/stage-engine.py --save $SaveEngineProducts --binary $taskBinary --configuration $Configuration.ToLowerInvariant() --architecture $Architecture
        if ($LASTEXITCODE -ne 0) { throw 'Could not save Windows engine products.' }
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
