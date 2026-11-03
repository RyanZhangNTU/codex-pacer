param([ValidateSet('x64','arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-PacerWinSparkleSHA256([string]$Path) {
    $taskInput = [IO.File]::OpenRead($Path)
    $taskHash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($taskHash.ComputeHash($taskInput))).Replace('-','').ToLowerInvariant() }
    finally { $taskHash.Dispose(); $taskInput.Dispose() }
}
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskLock = Get-Content -LiteralPath (Join-Path $taskRoot 'windows/winsparkle-lock.json') -Raw | ConvertFrom-Json
$taskCache = Join-Path $taskRoot 'output/toolchains/winsparkle'
$taskArchive = Join-Path $taskCache ('WinSparkle-' + $taskLock.version + '.zip')
$taskDestination = Join-Path $taskCache ($taskLock.version + '/' + $Architecture)
New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
if (!(Test-Path -LiteralPath $taskArchive)) { Invoke-WebRequest -Uri $taskLock.url -OutFile $taskArchive -MaximumRedirection 3 }
if ((Get-PacerWinSparkleSHA256 $taskArchive) -cne $taskLock.sha256) { throw 'WinSparkle archive hash mismatch.' }
$taskZip = [IO.Compression.ZipFile]::OpenRead($taskArchive)
try {
    $taskPrefix = 'WinSparkle-' + $taskLock.version + '/'
    foreach ($taskName in @('WinSparkle.dll','COPYING','COPYING.expat')) {
        $taskEntryName = if ($taskName -eq 'WinSparkle.dll') { $taskLock.files.$Architecture.entry } else { $taskName }
        $taskEntry = $taskZip.GetEntry($taskPrefix + $taskEntryName)
        if (!$taskEntry -or $taskEntry.Length -gt 8MB) { throw 'Unexpected WinSparkle package entry.' }
        $taskTarget = Join-Path $taskDestination $taskName
        [IO.Compression.ZipFileExtensions]::ExtractToFile($taskEntry, $taskTarget, $true)
    }
} finally { $taskZip.Dispose() }
if ((Get-PacerWinSparkleSHA256 (Join-Path $taskDestination 'WinSparkle.dll')) -cne $taskLock.files.$Architecture.sha256) { throw 'WinSparkle native library hash mismatch.' }
Write-Output $taskDestination
