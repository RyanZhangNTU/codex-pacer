param([Parameter(Mandatory=$true)][string]$Archive)
# Patch installer lifecycle in an isolated QA scope: a synthetic next build
# changes, adds and drops one file each. The patch must refuse an installation
# that is not exactly its base, leaving it untouched, and turn the base into
# the next build file for file. No application is started.
. (Join-Path $PSScriptRoot 'environment.ps1')
$ErrorActionPreference = 'Stop'
$taskScope = [Guid]::NewGuid().ToString('N')
$taskFixture = Join-Path $taskRoot ('out/pacer-patch-check-' + $taskScope.Substring(0,8))
$taskApp = [IO.Path]::GetFullPath((Join-Path $taskFixture '中文 空格/应用'))
$taskDesktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) ('Codex Pacer QA ' + $taskScope + '.lnk')
$taskPreviousBundleCache = $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $taskFixture 'bundle-cache'
$taskPasses = [Collections.Generic.List[string]]::new()
$taskInstalled = $false
$taskFailure = $null
New-Item -ItemType Directory -Path $taskFixture -Force | Out-Null

function Assert-Pacer([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Record-Pacer([string]$Name) { $taskPasses.Add($Name); Write-Output ('PASS ' + $Name) }
function Get-PacerDigest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-PacerSetup([string]$File, [string[]]$Arguments) {
    $taskStart = [Diagnostics.ProcessStartInfo]::new($File)
    $taskStart.UseShellExecute = $false; $taskStart.CreateNoWindow = $true
    foreach ($taskArgument in $Arguments) { $taskStart.ArgumentList.Add($taskArgument) }
    $taskProcess = [Diagnostics.Process]::Start($taskStart)
    try {
        if (!$taskProcess.WaitForExit(300000)) { $taskProcess.Kill($true); throw 'A patch test installer exceeded five minutes.' }
        $taskLogFlag = $Arguments | Where-Object { $_.StartsWith('/LOG=', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($taskLogFlag) {
            # Setup's loader can exit just before its worker closes the log.
            $taskDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ($taskDeadline.Elapsed.TotalSeconds -lt 10) {
                try { ([IO.File]::Open($taskLogFlag.Substring(5), 'Open', 'Read', 'None')).Dispose(); break } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
            }
        }
        return $taskProcess.ExitCode
    } finally { $taskProcess.Dispose() }
}
# Changes one listed file of a payload and records its new hash.
function Set-PacerPayloadFile([string]$Payload, [string]$Relative, [string]$Text) {
    $taskPath = Join-Path $Payload $Relative
    New-Item -ItemType Directory -Path (Split-Path $taskPath -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($taskPath, $Text, [Text.UTF8Encoding]::new($false))
    $taskInfoPath = Join-Path $Payload 'build-info.json'
    $taskInfo = Get-Content -LiteralPath $taskInfoPath -Raw | ConvertFrom-Json
    foreach ($taskFile in $taskInfo.files) { if ($taskFile.path -eq $Relative) { $taskFile.sha256 = Get-PacerDigest $taskPath } }
    [IO.File]::WriteAllText($taskInfoPath, ($taskInfo | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

try {
    $taskSource = Join-Path $taskFixture 'source'
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $taskSource)
    $taskChanged = 'Assets/Fonts/LICENSE.txt'
    Assert-Pacer (Test-Path -LiteralPath (Join-Path $taskSource $taskChanged)) 'The fixture file to change is missing from the payload.'
    $taskBasePayload = Join-Path $taskFixture 'base'
    $taskNextPayload = Join-Path $taskFixture 'next'
    Copy-Item -LiteralPath $taskSource -Destination $taskBasePayload -Recurse
    Move-Item -LiteralPath $taskSource -Destination $taskNextPayload
    # The base ships a file the next build drops; the next build changes one and adds one.
    $taskObsolete = 'synthetic-obsolete/obsolete.txt'
    New-Item -ItemType Directory -Path (Join-Path $taskBasePayload 'synthetic-obsolete') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $taskBasePayload $taskObsolete), 'synthetic file the next build drops', [Text.UTF8Encoding]::new($false))
    Set-PacerPayloadFile $taskNextPayload $taskChanged ([IO.File]::ReadAllText((Join-Path $taskNextPayload $taskChanged)) + "`nsynthetic patch change`n")
    $taskAdded = 'synthetic-added.txt'
    [IO.File]::WriteAllText((Join-Path $taskNextPayload $taskAdded), 'synthetic file the patch adds', [Text.UTF8Encoding]::new($false))

    $null = & (Join-Path $PSScriptRoot 'package-installer.ps1') -Archive $taskBasePayload -QaScope $taskScope -Compression 'lzma2/fast'
    $taskReceipt = Get-Content -LiteralPath (Join-Path $taskRoot 'output/windows/installer-qa-location.json') -Raw | ConvertFrom-Json
    $taskBaseSetup = Join-Path $taskFixture 'base-setup.exe'
    $taskBaseManifest = Join-Path $taskFixture 'base-manifest.json'
    Copy-Item -LiteralPath $taskReceipt.installer -Destination $taskBaseSetup
    Copy-Item -LiteralPath $taskReceipt.manifest -Destination $taskBaseManifest
    $null = & (Join-Path $PSScriptRoot 'package-installer.ps1') -Archive $taskNextPayload -QaScope $taskScope -Compression 'lzma2/fast' -BaseManifest $taskBaseManifest
    $taskNext = Get-Content -LiteralPath (Join-Path $taskRoot 'output/windows/installer-qa-location.json') -Raw | ConvertFrom-Json
    $taskPatchReceipt = Get-Content -LiteralPath (Join-Path $taskRoot 'output/windows/patch-qa-location.json') -Raw | ConvertFrom-Json
    $taskPatch = Join-Path $taskFixture 'patch.exe'
    Copy-Item -LiteralPath $taskPatchReceipt.installer -Destination $taskPatch
    $taskPatchInfo = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($taskPatchReceipt.installer, '.json')) -Raw | ConvertFrom-Json
    Assert-Pacer ($taskPatchInfo.baseManifestSHA256 -eq (Get-PacerDigest $taskBaseManifest) -and $taskPatchInfo.manifestSHA256 -eq (Get-PacerDigest $taskNext.manifest)) 'The patch metadata names the wrong manifests.'
    Assert-Pacer ($taskPatchInfo.files -eq 3) ('The patch must carry the changed file, the added file and the maintenance host; it carries ' + $taskPatchInfo.files + '.')
    Assert-Pacer ((Get-Item -LiteralPath $taskPatch).Length -lt (Get-Item -LiteralPath $taskNext.installer).Length / 2) 'The patch is not substantially smaller than the full installer.'
    Record-Pacer ('patch carries only changed files ({0:n1} MB against {1:n1} MB in full)' -f ((Get-Item -LiteralPath $taskPatch).Length / 1MB), ((Get-Item -LiteralPath $taskNext.installer).Length / 1MB))

    $taskFlags = @('/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/LANG=english',('/DIR=' + $taskApp))
    Assert-Pacer ((Invoke-PacerSetup $taskBaseSetup $taskFlags) -eq 0) 'The base installation failed.'
    $taskInstalled = $true
    $taskInstalledManifest = Join-Path $taskApp 'build-info.json'
    Assert-Pacer ((Get-PacerDigest $taskInstalledManifest) -eq (Get-PacerDigest $taskBaseManifest) -and (Test-Path -LiteralPath (Join-Path $taskApp $taskObsolete))) 'The base installation is not the patch base.'

    # Not exactly the base: one untouched file differs. Nothing may change.
    $taskTampered = Join-Path $taskApp 'LICENSE.txt'
    $taskOriginal = [IO.File]::ReadAllBytes($taskTampered)
    [IO.File]::WriteAllText($taskTampered, 'synthetic local modification', [Text.UTF8Encoding]::new($false))
    $taskChangedBefore = Get-PacerDigest (Join-Path $taskApp $taskChanged)
    $taskRefusal = Join-Path $taskFixture 'patch-refused.log'
    Assert-Pacer ((Invoke-PacerSetup $taskPatch ($taskFlags + ('/LOG=' + $taskRefusal))) -ne 0) 'A patch installed over a modified installation.'
    Assert-Pacer ((Get-PacerDigest $taskInstalledManifest) -eq (Get-PacerDigest $taskBaseManifest) -and (Get-PacerDigest (Join-Path $taskApp $taskChanged)) -eq $taskChangedBefore -and
        !(Test-Path -LiteralPath (Join-Path $taskApp $taskAdded)) -and (Test-Path -LiteralPath (Join-Path $taskApp $taskObsolete))) 'A refused patch changed the installation.'
    [IO.File]::WriteAllBytes($taskTampered, $taskOriginal)
    Record-Pacer 'a modified installation refuses the patch before any file changes'

    $taskLog = Join-Path $taskFixture 'patch.log'
    $taskCode = Invoke-PacerSetup $taskPatch ($taskFlags + ('/LOG=' + $taskLog))
    if ($taskCode -ne 0) {
        # Synthetic fixture only: the log holds paths and step names, no user data.
        if (Test-Path -LiteralPath $taskLog) { Get-Content -LiteralPath $taskLog -Tail 30 | ForEach-Object { Write-Host ('  setup: ' + $_) } }
        throw ('The patch did not install over its base (exit code ' + $taskCode + ').')
    }
    Assert-Pacer ((Get-PacerDigest $taskInstalledManifest) -eq (Get-PacerDigest $taskNext.manifest)) 'The patched installation does not carry the next manifest.'
    $taskExpected = Get-Content -LiteralPath $taskNext.manifest -Raw | ConvertFrom-Json
    foreach ($taskFile in $taskExpected.files) {
        $taskPath = Join-Path $taskApp $taskFile.path
        Assert-Pacer ((Test-Path -LiteralPath $taskPath) -and (Get-PacerDigest $taskPath) -eq $taskFile.sha256) ('A patched file differs from the next build: ' + $taskFile.path)
    }
    Assert-Pacer (!(Test-Path -LiteralPath (Join-Path $taskApp $taskObsolete)) -and !(Test-Path -LiteralPath (Join-Path $taskApp 'synthetic-obsolete'))) 'The patch left a file the next build dropped.'
    Assert-Pacer ([IO.File]::ReadAllText($taskLog).Contains('Installation process succeeded')) 'The patch log does not record success.'
    Record-Pacer 'the patch turns its base into the next build file for file, including added and dropped files'

    $taskSecond = Join-Path $taskFixture 'patch-again.log'
    Assert-Pacer ((Invoke-PacerSetup $taskPatch ($taskFlags + ('/LOG=' + $taskSecond))) -ne 0) 'A patch applied to an installation that is no longer its base.'
    Assert-Pacer ((Get-PacerDigest $taskInstalledManifest) -eq (Get-PacerDigest $taskNext.manifest)) 'A refused second patch changed the installation.'
    Record-Pacer 'the same patch refuses an installation that is already the next build'

    Assert-Pacer ((Invoke-PacerSetup $taskBaseSetup $taskFlags) -eq 0) 'Could not reinstall the isolated patch base.'
    $taskVerifyLog = Join-Path $taskFixture 'patch-verification-failed.log'
    $taskVerifyCode = Invoke-PacerSetup $taskPatch ($taskFlags + '/PACERQADAMAGEPATCH=1' + ('/LOG=' + $taskVerifyLog))
    Assert-Pacer ($taskVerifyCode -eq 21 -and [IO.File]::ReadAllText($taskVerifyLog).Contains('Pacer post-install failure 21') -and
        (Get-PacerDigest $taskInstalledManifest) -eq (Get-PacerDigest $taskNext.manifest) -and
        !(Test-Path -LiteralPath (Join-Path $taskApp $taskAdded))) 'Post-install patch verification did not signal failure after replacing files.'
    # Simulate the relaunch having recorded the failure. Launch the full
    # installer directly, with no updater helper or result file.
    $taskUpdates = Join-Path (Split-Path $taskApp -Parent) ('CodexPacer-QA-' + $taskScope + '/Updates')
    $taskUpdateState = Join-Path $taskUpdates 'state-v1.json'
    New-Item -ItemType Directory -Path $taskUpdates -Force | Out-Null
    $taskFailedBuild = [string]$taskExpected.version + '.' + [string]$taskExpected.build
    @{ SchemaVersion = 1; Values = @{ PacerPatchFailedBuild = $taskFailedBuild; SkipThisVersion = '1.0.0.1' } } |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $taskUpdateState -Encoding utf8
    Assert-Pacer ((Invoke-PacerSetup $taskNext.installer $taskFlags) -eq 0 -and (Test-Path -LiteralPath (Join-Path $taskApp $taskAdded))) 'The full installer did not repair the failed patch.'
    $taskAfterRepair = Get-Content -LiteralPath $taskUpdateState -Raw | ConvertFrom-Json -AsHashtable
    Assert-Pacer (!$taskAfterRepair['Values'].Contains('PacerPatchFailedBuild') -and
        $taskAfterRepair['Values']['SkipThisVersion'] -eq '1.0.0.1') 'Manual repair did not clear only the failed patch marker.'
    Record-Pacer 'a post-install verification failure exits nonzero and a manual full repair clears its marker'

    # The uninstaller hands over to a temporary copy; its log closes when that copy is done.
    $taskUninstallLog = Join-Path $taskFixture 'uninstall.log'
    Assert-Pacer ((Invoke-PacerSetup (Join-Path $taskApp 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG=' + $taskUninstallLog))) -eq 0) 'Uninstall after a patch failed.'
    $taskInstalled = $false
    for ($taskWait = 0; $taskWait -lt 50 -and (Test-Path -LiteralPath $taskApp); $taskWait++) { Start-Sleep -Milliseconds 200 }
    $taskLeft = @(if (Test-Path -LiteralPath $taskApp) { Get-ChildItem -LiteralPath $taskApp -Recurse -Force | ForEach-Object { [IO.Path]::GetRelativePath($taskApp, $_.FullName) } })
    Assert-Pacer (!(Test-Path -LiteralPath $taskApp) -and !(Test-Path -LiteralPath $taskDesktopShortcut)) ('Uninstall after a patch left files or a shortcut behind: ' +
        $(if (Test-Path -LiteralPath $taskDesktopShortcut) { 'desktop shortcut; ' } else { '' }) + ($taskLeft -join ', '))
    Record-Pacer 'uninstall after a patch removes every file, including ones the patch added'
    $taskReport = @{ schemaVersion=1; syntheticOnly=$true; checks=@($taskPasses) }
    [IO.File]::WriteAllText((Join-Path $taskRoot 'output/windows/patch-tests.json'), ($taskReport | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
} catch {
    $taskFailure = $_
    Write-Host ('FAIL patch lifecycle after: ' + ($taskPasses | Select-Object -Last 1))
    throw
} finally {
    if ($taskInstalled -and (Test-Path -LiteralPath (Join-Path $taskApp 'unins000.exe'))) {
        $null = Invoke-PacerSetup (Join-Path $taskApp 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    }
    if (Test-Path -LiteralPath $taskDesktopShortcut) { Remove-Item -LiteralPath $taskDesktopShortcut -Force }
    $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = $taskPreviousBundleCache
    $taskResolved = [IO.Path]::GetFullPath($taskFixture)
    $taskAllowed = [IO.Path]::GetFullPath((Join-Path $taskRoot 'out')).TrimEnd('\') + '\'
    if ($taskResolved.StartsWith($taskAllowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $taskResolved -Leaf).StartsWith('pacer-patch-check-')) {
        try { Remove-Item -LiteralPath $taskResolved -Recurse -Force }
        catch { if (!$taskFailure) { throw }; Write-Host 'Patch fixture cleanup was incomplete; the original failure is preserved.' }
    }
}
