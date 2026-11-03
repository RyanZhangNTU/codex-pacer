$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskPin = Get-Content -LiteralPath (Join-Path $taskRoot 'windows/InstallerSupport/Resources/python-runtime-lock.json') -Raw | ConvertFrom-Json
$taskId = $taskPin.version + '-' + $taskPin.sha256.Substring(0,12)
$taskCache = Join-Path $taskRoot 'output/toolchains/claude-python'
$taskRuntime = Join-Path $taskCache $taskId
$taskArchive = Join-Path $taskCache ('python-' + $taskPin.version + '-embed-amd64.zip')
New-Item -ItemType Directory -Path $taskCache -Force | Out-Null
if (!(Test-Path -LiteralPath $taskArchive)) {
    Invoke-WebRequest -Uri $taskPin.url -OutFile $taskArchive -MaximumRedirection 3
}
if ((Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskPin.sha256) {
    throw 'The embedded Python archive does not match the pinned official hash.'
}
New-Item -ItemType Directory -Path $taskRuntime -Force | Out-Null
$taskZip = [IO.Compression.ZipFile]::OpenRead($taskArchive)
$taskFiles = [Collections.Generic.List[object]]::new()
try {
    foreach ($taskEntry in $taskZip.Entries) {
        if ($taskEntry.FullName -ne $taskEntry.Name -or !$taskEntry.Name -or $taskEntry.Length -gt 16MB) {
            throw 'Unexpected embedded Python archive entry.'
        }
        $taskInput = $taskEntry.Open()
        try { $taskExpected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($taskInput)).ToLowerInvariant() }
        finally { $taskInput.Dispose() }
        $taskTarget = Join-Path $taskRuntime $taskEntry.Name
        if (!(Test-Path -LiteralPath $taskTarget) -or (Get-FileHash -LiteralPath $taskTarget -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskExpected) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($taskEntry,$taskTarget,$true)
        }
        $taskFiles.Add(@{name=$taskEntry.Name;sha256=$taskExpected;bytes=$taskEntry.Length})
    }
} finally { $taskZip.Dispose() }
foreach ($taskName in $taskPin.signedFiles) {
    $taskSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $taskRuntime $taskName)
    if ($taskSignature.Status -ne 'Valid' -or $taskSignature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $taskPin.signer) {
        throw 'The embedded Python publisher signature is not the pinned signer.'
    }
}
if (!(Test-Path -LiteralPath (Join-Path $taskRuntime 'LICENSE.txt'))) { throw 'The embedded Python license is missing.' }
$taskManifest = @{schemaVersion=1;version=$taskPin.version;architecture=$taskPin.architecture;archiveSHA256=$taskPin.sha256;files=@($taskFiles)}
[IO.File]::WriteAllText((Join-Path $taskRuntime 'pacer-runtime.json'),($taskManifest|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Output $taskRuntime
