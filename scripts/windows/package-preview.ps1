param([switch]$SkipBuild)
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
Push-Location $taskRoot
try {
    python -S scripts/windows/check-contract.py
    if ($LASTEXITCODE -ne 0) { throw 'The platform contract must pass before packaging a preview.' }
    if (!$SkipBuild) { & (Join-Path $PSScriptRoot 'build-desktop.ps1') -Configuration Release }
    $taskVersion = Get-PacerVersion
    $taskCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'A source commit is required.' }
    $taskDirty = [bool](& git status --porcelain)
    $taskStamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $taskName = 'CodexPacer-' + $taskVersion.version + '-windows-x64-preview-' + $taskCommit.Substring(0,7)
    if ($taskDirty) { $taskName += '-worktree' }
    $taskOutput = Join-Path $taskRoot 'output/windows'
    $taskStaging = Join-Path $taskOutput ('preview-staging/' + [Guid]::NewGuid().ToString('N'))
    $taskApplication = Join-Path $taskStaging 'CodexPacer'
    New-Item -ItemType Directory -Path $taskApplication -Force | Out-Null
    dotnet publish windows/Desktop/Pacer.Windows.csproj --configuration Release --runtime win-x64 --self-contained true --output $taskApplication "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'The self-contained desktop publish failed.' }
    $taskDesktop = Join-Path $taskRoot 'windows/Desktop/bin/Release/net10.0-windows'
    foreach ($taskBundle in @('Engine','Maintenance','CodexPacerPortable_PacerCore.resources')) {
        $taskSource = Join-Path $taskDesktop $taskBundle
        if (!(Test-Path -LiteralPath $taskSource -PathType Container)) { throw ('Missing runtime bundle: ' + $taskBundle) }
        Copy-Item -LiteralPath $taskSource -Destination $taskApplication -Recurse
    }
    # The Swift installer supplies these Microsoft runtime DLLs. Also place
    # them beside the desktop host, whose notification SDK loads native code.
    foreach ($taskPattern in @('vcruntime*.dll','msvcp*.dll','concrt*.dll','vccorlib*.dll')) {
        Get-ChildItem -LiteralPath (Join-Path $taskApplication 'Engine') -Filter $taskPattern -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $taskApplication
        }
    }
    Copy-Item -LiteralPath (Join-Path $taskRoot 'docs/windows-preview.md') -Destination (Join-Path $taskApplication '开始使用.txt')
    Copy-Item -LiteralPath (Join-Path $taskRoot 'LICENSE') -Destination (Join-Path $taskApplication 'LICENSE.txt')
    $taskLicenses = Join-Path $taskApplication 'Licenses/Swift'
    New-Item -ItemType Directory -Path $taskLicenses -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $taskRoot 'windows/ThirdParty/Swift') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $taskLicenses }
    Copy-Item -LiteralPath (Join-Path $taskRoot 'native/Sources/CZstd/LICENSE') -Destination (Join-Path $taskApplication 'Licenses/Zstd-LICENSE.txt')
    [IO.File]::WriteAllText((Join-Path $taskApplication 'Demo.cmd'), "@echo off`r`nstart `"`" `"%~dp0CodexPacer.exe`" --demo`r`n", [Text.ASCIIEncoding]::new())
    $taskRuntimeConfig = Get-Content -LiteralPath (Join-Path $taskApplication 'CodexPacer.runtimeconfig.json') -Raw | ConvertFrom-Json
    $taskFrameworks = @($taskRuntimeConfig.runtimeOptions.includedFrameworks)
    if ($taskFrameworks.Count -lt 2) { throw 'The preview must include both .NET and Windows Desktop runtimes.' }
    foreach ($taskFramework in $taskFrameworks) {
        $taskPackage = if ($taskFramework.name -eq 'Microsoft.NETCore.App') { 'microsoft.netcore.app.runtime.win-x64' } elseif ($taskFramework.name -eq 'Microsoft.WindowsDesktop.App') { 'microsoft.windowsdesktop.app.runtime.win-x64' } else { throw 'Unexpected framework runtime.' }
        $taskPackagePath = Join-Path $env:NUGET_PACKAGES ($taskPackage + '/' + $taskFramework.version)
        $taskLicenseTarget = Join-Path $taskApplication ('Licenses/' + $taskPackage)
        New-Item -ItemType Directory -Path $taskLicenseTarget -Force | Out-Null
        $taskNotices = @(Get-ChildItem -LiteralPath $taskPackagePath -File | Where-Object { $_.Name -match '(?i)license|third.party.notices' })
        if ($taskNotices.Count -eq 0) { throw ('Runtime notices are missing: ' + $taskPackage) }
        foreach ($taskNotice in $taskNotices) { Copy-Item -LiteralPath $taskNotice.FullName -Destination $taskLicenseTarget }
    }
    $taskEngine = Get-Content -LiteralPath (Join-Path $taskRoot 'output/windows/engine-location.json') -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $taskApplication 'installation-identity.json'), '{"schemaVersion":1,"qaScope":null}', [Text.UTF8Encoding]::new($false))
    $taskFiles = @(Get-ChildItem -LiteralPath $taskApplication -File -Recurse | Sort-Object FullName | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($taskApplication, $_.FullName).Replace([char]92,[char]47); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $taskManifest = @{ schemaVersion=1; channel='development-preview'; version=$taskVersion.version; build=$taskVersion.build;
        sourceCommit=$taskCommit; sourceDirty=$taskDirty; builtAt=[DateTime]::UtcNow.ToString('o'); architecture='x64';
        minimumWindowsBuild=19041; signed=$false; automaticUpdates=$false; engineSourceHash=(Split-Path $taskEngine.source -Leaf);
        includedFrameworks=$taskFrameworks; toolchain=(Get-Content -LiteralPath windows/toolchain-lock.json -Raw | ConvertFrom-Json); files=$taskFiles }
    [IO.File]::WriteAllText((Join-Path $taskApplication 'build-info.json'), ($taskManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $taskArchive = Join-Path $taskOutput ($taskName + '-' + $taskStamp + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($taskApplication, $taskArchive, [IO.Compression.CompressionLevel]::Optimal, $false)
    $taskDigest = (Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(($taskArchive + '.sha256'), ($taskDigest + '  ' + [IO.Path]::GetFileName($taskArchive) + "`n"), [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'test-preview.ps1') -Archive $taskArchive
    Write-Output $taskArchive
} finally { Pop-Location }
