param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [string]$QaScope = ''
)
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
if ($taskInfo.schemaVersion -ne 1 -or $taskInfo.architecture -ne 'x64' -or $taskInfo.signed -ne $false) {
    throw 'The installer requires the unsigned x64 application payload.'
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
$taskName = 'CodexPacer-' + $taskVersion.version + '-windows-x64-setup-' + $taskInfo.sourceCommit.Substring(0,7)
if ($taskInfo.sourceDirty) { $taskName += '-worktree' }
$taskAppId = 'CodexPacer.Windows'; $taskAppName = 'Codex Pacer'
if ($taskScope -ne 'default') {
    $taskName += '-qa-' + $taskScope
    $taskAppId += '.QA.' + $taskScope
    $taskAppName += ' QA ' + $taskScope
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
    ('/DArtifactName=' + $taskName), (Join-Path $taskRoot 'windows/Installer/CodexPacer.iss')
)) { $taskStart.ArgumentList.Add($taskArgument) }
$taskCompiler = [Diagnostics.Process]::Start($taskStart)
try {
    $taskCompilerOut = $taskCompiler.StandardOutput.ReadToEndAsync()
    $taskCompilerErr = $taskCompiler.StandardError.ReadToEndAsync()
    $taskFinished = $false
    for ($taskAttempt = 0; $taskAttempt -lt 5; $taskAttempt++) {
        if ($taskCompiler.WaitForExit(60000)) { $taskFinished = $true; break }
        Write-Output 'The installer compiler is still running.'
    }
    if (!$taskFinished) { $taskCompiler.Kill($true); throw 'The installer compiler exceeded five minutes.' }
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
