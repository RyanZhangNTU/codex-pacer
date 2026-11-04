param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [string]$QaScope = '',
    # Release builds use the smallest package; QA builds may trade size for time.
    [ValidateSet('lzma2/ultra64','lzma2/max','lzma2/fast')][string]$Compression = 'lzma2/ultra64',
    [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }),
    # The previous release's build-info.json. Also builds a patch installer
    # that carries only the files changed since that build.
    [string]$BaseManifest = ''
)
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
. (Join-Path $PSScriptRoot 'setup-installer.ps1')
$taskInno = Get-PacerInstallerCompiler
$taskVersion = Get-PacerVersion
$taskScope = 'default'
if ($QaScope) { $taskScope = ([Guid]::ParseExact($QaScope, 'N')).ToString('N') }
$taskOutput = Join-Path $taskRoot 'output/windows'
$taskArtifacts = Join-Path $taskOutput $(if ($taskScope -eq 'default') { 'installer-artifact' } else { 'installer-qa' })
New-Item -ItemType Directory -Path $taskArtifacts -Force | Out-Null
$taskPayload = Join-Path $taskRoot ('out/installer-payload-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskPayload -Force | Out-Null
# Lifecycle tests may pass an already extracted payload directory.
if (Test-Path -LiteralPath $Archive -PathType Container) { Copy-Item -Path (Join-Path ([IO.Path]::GetFullPath($Archive)) '*') -Destination $taskPayload -Recurse -Force }
else { [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $taskPayload) }
$taskInfoFile = Join-Path $taskPayload 'build-info.json'
$taskInfo = Get-Content -LiteralPath $taskInfoFile -Raw | ConvertFrom-Json
if ($taskInfo.schemaVersion -ne 1 -or $taskInfo.architecture -ne $Architecture -or $taskInfo.signed -ne $false -or $taskInfo.minimumWindowsBuild -ne 19041) {
    throw 'The installer requires an unsigned application payload matching its target architecture and minimum Windows build.'
}
foreach ($taskFile in $taskInfo.files) {
    $taskCandidate = [IO.Path]::GetFullPath((Join-Path $taskPayload $taskFile.path))
    if (!$taskCandidate.StartsWith($taskPayload + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-FileHash -LiteralPath $taskCandidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskFile.sha256) {
        throw 'The application payload hash is invalid.'
    }
}
$taskIdentity = @{ schemaVersion=1; qaScope=if ($taskScope -eq 'default') { $null } else { $taskScope } }
[IO.File]::WriteAllText((Join-Path $taskPayload 'installation-identity.json'), ($taskIdentity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$taskInfo.files = @(Get-ChildItem -LiteralPath $taskPayload -File -Recurse | Where-Object { $_.FullName -ne $taskInfoFile } | Sort-Object FullName | ForEach-Object {
    @{ path=[IO.Path]::GetRelativePath($taskPayload, $_.FullName).Replace([char]92,[char]47); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
[IO.File]::WriteAllText($taskInfoFile, ($taskInfo | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
$taskName = 'CodexPacer-' + $taskVersion.version + '-windows-' + $Architecture + '-setup-' + $taskInfo.sourceCommit.Substring(0,7)
if ($taskInfo.sourceDirty) { $taskName += '-worktree' }
$taskAppId = 'CodexPacer.Windows'; $taskAppName = 'Codex Pacer'
if ($taskScope -ne 'default') {
    $taskName += '-qa-' + $taskScope
    $taskAppId += '.QA.' + $taskScope
    $taskAppName += ' QA ' + $taskScope
}
# The vendored Chinese messages are compiled into every installer; pin them.
$taskLanguages = Join-Path $taskRoot 'windows/ThirdParty/InnoSetup'
foreach ($taskSource in (Get-Content -LiteralPath (Join-Path $taskLanguages 'provenance.json') -Raw | ConvertFrom-Json).sources) {
    $taskText = [IO.File]::ReadAllText((Join-Path $taskLanguages $taskSource.name), [Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n")
    $taskDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($taskText))).ToLowerInvariant()
    if ($taskDigest -ne $taskSource.sha256) { throw ('A vendored installer language file changed: ' + $taskSource.name) }
}
function Get-PacerDigest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
# Writes NAME.sha256 beside an artifact, in the format the release Mac checks.
function Write-PacerChecksum([string]$Path) {
    $taskDigest = Get-PacerDigest $Path
    [IO.File]::WriteAllText(($Path + '.sha256'), ($taskDigest + '  ' + [IO.Path]::GetFileName($Path) + [char]10), [Text.UTF8Encoding]::new($false))
    return $taskDigest
}
function Invoke-PacerInno([string]$Source, [string]$Name, [string]$Log, [string[]]$Extra) {
    $taskStart = [Diagnostics.ProcessStartInfo]::new($taskInno)
    $taskStart.UseShellExecute = $false
    $taskStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $taskStart.CreateNoWindow = $true
    $taskStart.RedirectStandardOutput = $true
    $taskStart.RedirectStandardError = $true
    foreach ($taskArgument in @(
        ('/DSourceDir=' + $Source), ('/DPacerAssetsDir=' + $taskPayload), ('/DArtifactDir=' + $taskArtifacts),
        ('/DPacerVersion=' + $taskVersion.version), ('/DPacerFileVersion=' + $taskVersion.version + '.' + $taskVersion.build),
        ('/DPacerScope=' + $taskScope), ('/DPacerAppId=' + $taskAppId), ('/DPacerAppName=' + $taskAppName),
        ('/DArtifactName=' + $Name), ('/DPacerArchitecture=' + $Architecture), ('/DPacerCompression=' + $Compression)
    ) + $Extra + @((Join-Path $taskRoot 'windows/Installer/CodexPacer.iss'))) { $taskStart.ArgumentList.Add($taskArgument) }
    $taskCompiler = [Diagnostics.Process]::Start($taskStart)
    try {
        $taskCompilerOut = $taskCompiler.StandardOutput.ReadToEndAsync()
        $taskCompilerErr = $taskCompiler.StandardError.ReadToEndAsync()
        $taskFinished = $false
        for ($taskAttempt = 0; $taskAttempt -lt 15; $taskAttempt++) {
            if ($taskCompiler.WaitForExit(60000)) { $taskFinished = $true; break }
            Write-Host 'The installer compiler is still running.'
        }
        if (!$taskFinished) { $taskCompiler.Kill($true); throw 'The installer compiler exceeded fifteen minutes.' }
        $taskCompilerText = $taskCompilerOut.GetAwaiter().GetResult() + $taskCompilerErr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $taskOutput $Log), $taskCompilerText, [Text.UTF8Encoding]::new($false))
        if ($taskCompiler.ExitCode -ne 0 -or $taskCompilerText -match '(?im)^Warning:') { throw 'The installer compiler failed or reported a warning. See the local compiler log.' }
    }
    finally { $taskCompiler.Dispose() }
    return (Join-Path $taskArtifacts ($Name + '.exe'))
}
$taskInstaller = Invoke-PacerInno $taskPayload $taskName ('installer-compile-' + $taskScope + '.log') @()
Write-Output 'PASS unsigned installer compiled without warnings.'
$taskHash = Write-PacerChecksum $taskInstaller
# The manifest a later release's patch is built against, published with this one.
$taskManifest = Join-Path $taskArtifacts ($taskName.Replace('-setup-', '-manifest-') + '.json')
Copy-Item -LiteralPath $taskInfoFile -Destination $taskManifest -Force
$taskManifestHash = Write-PacerChecksum $taskManifest
$taskReceipt = @{ schemaVersion=1; installer=$taskInstaller; payload=$taskPayload; scope=$taskScope; appId=$taskAppId; sha256=$taskHash; compilerVersion='6.7.4';
    manifest=$taskManifest; manifestSHA256=$taskManifestHash }
$taskReceiptName = if ($taskScope -eq 'default') { 'installer-location.json' } else { 'installer-qa-location.json' }
[IO.File]::WriteAllText((Join-Path $taskOutput $taskReceiptName), ($taskReceipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

if ($BaseManifest) {
    # The patch carries every file whose content differs from the base, plus
    # the new manifest and maintenance host. Removed files are cleaned by the
    # usual stale-file pass, which compares the installed and new manifests.
    $taskBaseBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($BaseManifest))
    $taskBase = [Text.Encoding]::UTF8.GetString($taskBaseBytes) | ConvertFrom-Json
    if ($taskBase.schemaVersion -ne 1 -or $taskBase.architecture -ne $Architecture -or !$taskBase.version -or !$taskBase.build) {
        throw 'The patch base must be a build-info.json for the same architecture.'
    }
    $taskBaseBuild = [string]$taskBase.version + '.' + [string]$taskBase.build
    # QA lifecycle tests patch a synthetic change of the same build.
    if ($taskScope -eq 'default' -and [Version]$taskBaseBuild -ge [Version]($taskVersion.version + '.' + $taskVersion.build)) { throw 'The patch base must be an earlier build.' }
    $taskBaseDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($taskBaseBytes)).ToLowerInvariant()
    $taskBefore = @{}
    foreach ($taskFile in $taskBase.files) { $taskBefore[[string]$taskFile.path] = [string]$taskFile.sha256 }
    $taskCarried = [Collections.Generic.List[string]]::new()
    $taskCarried.Add('Maintenance/PacerMaintenance.exe')
    foreach ($taskFile in $taskInfo.files) {
        if ($taskBefore[$taskFile.path] -ne $taskFile.sha256 -and !$taskCarried.Contains($taskFile.path)) { $taskCarried.Add($taskFile.path) }
    }
    $taskPatchPayload = Join-Path $taskRoot ('out/installer-patch-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    foreach ($taskRelative in @($taskCarried) + @('build-info.json')) {
        $taskTarget = Join-Path $taskPatchPayload $taskRelative
        New-Item -ItemType Directory -Path (Split-Path $taskTarget -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $taskPayload $taskRelative) -Destination $taskTarget
    }
    $taskPatchMeta = Join-Path $taskRoot ('out/installer-patch-meta-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $taskPatchMeta -Force | Out-Null
    $taskPatchFile = Join-Path $taskPatchMeta 'pacer-patch.json'
    $taskDescription = [ordered]@{ schemaVersion=1; baseBuild=$taskBaseBuild; baseManifestSHA256=$taskBaseDigest; files=@($taskCarried) }
    [IO.File]::WriteAllText($taskPatchFile, ($taskDescription | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $taskPatchName = $taskName.Replace('-setup-', '-patch-')
    $taskPatch = Invoke-PacerInno $taskPatchPayload $taskPatchName ('installer-compile-' + $taskScope + '-patch.log') @('/DPacerPatch=1', ('/DPacerPatchFile=' + $taskPatchFile))
    $taskPatchHash = Write-PacerChecksum $taskPatch
    $taskPatchInfo = [ordered]@{ schemaVersion=1; version=$taskVersion.version; build=($taskVersion.version + '.' + $taskVersion.build); architecture=$Architecture
        baseVersion=[string]$taskBase.version; baseBuild=$taskBaseBuild; baseManifestSHA256=$taskBaseDigest; manifestSHA256=$taskManifestHash
        installer=[IO.Path]::GetFileName($taskPatch); sha256=$taskPatchHash; files=$taskCarried.Count }
    [IO.File]::WriteAllText((Join-Path $taskArtifacts ($taskPatchName + '.json')), ($taskPatchInfo | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $taskPatchReceipt = [ordered]@{ schemaVersion=1; installer=$taskPatch; sha256=$taskPatchHash; baseBuild=$taskBaseBuild; baseManifestSHA256=$taskBaseDigest; manifestSHA256=$taskManifestHash }
    [IO.File]::WriteAllText((Join-Path $taskOutput ($(if ($taskScope -eq 'default') { 'patch-location.json' } else { 'patch-qa-location.json' }))), ($taskPatchReceipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Output ('PASS patch installer from {0}: {1} files, {2:n1} MB' -f $taskBaseBuild, $taskCarried.Count, ((Get-Item -LiteralPath $taskPatch).Length / 1MB))
}
Write-Output $taskInstaller
