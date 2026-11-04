param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [string]$QaScope = '',
    # Release builds use the smallest package; QA builds may trade size for time.
    [ValidateSet('lzma2/ultra64','lzma2/max','lzma2/fast')][string]$Compression = 'lzma2/ultra64',
    [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' })
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
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $taskPayload)
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
$taskStart = [Diagnostics.ProcessStartInfo]::new($taskInno)
$taskStart.UseShellExecute = $false
$taskStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$taskStart.CreateNoWindow = $true
$taskStart.RedirectStandardOutput = $true
$taskStart.RedirectStandardError = $true
foreach ($taskArgument in @(
    ('/DSourceDir=' + $taskPayload), ('/DArtifactDir=' + $taskArtifacts),
    ('/DPacerVersion=' + $taskVersion.version), ('/DPacerFileVersion=' + $taskVersion.version + '.' + $taskVersion.build),
    ('/DPacerScope=' + $taskScope), ('/DPacerAppId=' + $taskAppId), ('/DPacerAppName=' + $taskAppName),
    ('/DArtifactName=' + $taskName), ('/DPacerArchitecture=' + $Architecture), ('/DPacerCompression=' + $Compression),
    (Join-Path $taskRoot 'windows/Installer/CodexPacer.iss')
)) { $taskStart.ArgumentList.Add($taskArgument) }
$taskCompiler = [Diagnostics.Process]::Start($taskStart)
try {
    $taskCompilerOut = $taskCompiler.StandardOutput.ReadToEndAsync()
    $taskCompilerErr = $taskCompiler.StandardError.ReadToEndAsync()
    $taskFinished = $false
    for ($taskAttempt = 0; $taskAttempt -lt 15; $taskAttempt++) {
        if ($taskCompiler.WaitForExit(60000)) { $taskFinished = $true; break }
        Write-Output 'The installer compiler is still running.'
    }
    if (!$taskFinished) { $taskCompiler.Kill($true); throw 'The installer compiler exceeded fifteen minutes.' }
    $taskCompilerText = $taskCompilerOut.GetAwaiter().GetResult() + $taskCompilerErr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $taskOutput ('installer-compile-' + $taskScope + '.log')), $taskCompilerText, [Text.UTF8Encoding]::new($false))
    if ($taskCompiler.ExitCode -ne 0 -or $taskCompilerText -match '(?im)^Warning:') { throw 'The installer compiler failed or reported a warning. See the local compiler log.' }
    Write-Output 'PASS unsigned installer compiled without warnings.'
}
finally { $taskCompiler.Dispose() }
$taskInstaller = Join-Path $taskArtifacts ($taskName + '.exe')
$taskHash = (Get-FileHash -LiteralPath $taskInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($taskInstaller + '.sha256'), ($taskHash + '  ' + [IO.Path]::GetFileName($taskInstaller) + [char]10), [Text.UTF8Encoding]::new($false))
$taskReceipt = @{ schemaVersion=1; installer=$taskInstaller; payload=$taskPayload; scope=$taskScope; appId=$taskAppId; sha256=$taskHash; compilerVersion='6.7.4' }
$taskReceiptName = if ($taskScope -eq 'default') { 'installer-location.json' } else { 'installer-qa-location.json' }
[IO.File]::WriteAllText((Join-Path $taskOutput $taskReceiptName), ($taskReceipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output $taskInstaller
