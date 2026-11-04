param(
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' })
)
# Finds the build-info.json of the latest published Windows build, so CI can
# build a patch installer from it. The latest feed names that build and the
# manifest's SHA-256; the manifest is a release asset of the same version.
# Without one (releases up to 4.2.2 publish no manifest) only the full
# installer is built. The release Mac checks the base again against the
# signed feed, and the app and installer check it against the installation.
$ErrorActionPreference = 'Stop'
$taskRepository = 'https://github.com/RyanZhangNTU/codex-pacer/releases'
$taskSparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
$taskPacer = 'urn:codex-pacer:windows-update'
$taskTemporary = Join-Path ([IO.Path]::GetTempPath()) ('pacer-update-base-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemporary -Force | Out-Null
try {
    $taskFeed = Join-Path $taskTemporary 'appcast-windows.xml'
    try { Invoke-WebRequest -Uri ($taskRepository + '/latest/download/appcast-windows.xml') -OutFile $taskFeed -MaximumRedirection 5 -TimeoutSec 60 -UseBasicParsing }
    catch { Write-Output 'No patch base: the latest Windows feed is unavailable.'; return }
    $taskBytes = [IO.File]::ReadAllBytes($taskFeed)
    $taskNewline = [Array]::IndexOf($taskBytes, [byte]10)
    if ($taskNewline -lt 0 -or $taskNewline -gt 256) { throw 'The latest Windows feed has no signature line.' }
    $taskDocument = [Xml.XmlDocument]::new()
    $taskDocument.XmlResolver = $null
    $taskDocument.LoadXml([Text.Encoding]::UTF8.GetString($taskBytes, $taskNewline + 1, $taskBytes.Length - $taskNewline - 1))
    $taskNames = [Xml.XmlNamespaceManager]::new($taskDocument.NameTable)
    $taskNames.AddNamespace('sparkle', $taskSparkle)
    $taskItem = $null
    foreach ($taskCandidate in $taskDocument.SelectNodes('/rss/channel/item')) {
        $taskEnclosure = $taskCandidate.SelectSingleNode('enclosure')
        if ($taskEnclosure -and $taskEnclosure.GetAttribute('os', $taskSparkle) -eq ('windows-' + $Architecture)) { $taskItem = $taskCandidate; break }
    }
    if (!$taskItem) { Write-Output ('No patch base: the latest feed has no ' + $Architecture + ' build.'); return }
    $taskDigest = $taskItem.SelectSingleNode('enclosure').GetAttribute('manifestSHA256', $taskPacer).ToLowerInvariant()
    $taskVersion = $taskItem.SelectSingleNode('sparkle:shortVersionString', $taskNames).InnerText
    $taskBuild = $taskItem.SelectSingleNode('sparkle:version', $taskNames).InnerText
    if ($taskDigest -notmatch '^[0-9a-f]{64}$') { Write-Output ('No patch base: ' + $taskVersion + ' publishes no Windows manifest.'); return }
    $taskName = 'Codex-Pacer-' + $taskVersion + '-windows-' + $Architecture + '-manifest.json'
    $taskManifest = Join-Path $taskTemporary $taskName
    Invoke-WebRequest -Uri ($taskRepository + '/download/v' + $taskVersion + '/' + $taskName) -OutFile $taskManifest -MaximumRedirection 5 -TimeoutSec 60 -UseBasicParsing
    if ((Get-FileHash -LiteralPath $taskManifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskDigest) { throw 'The published manifest differs from the latest feed.' }
    $taskInfo = Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json
    if ($taskInfo.architecture -ne $Architecture -or ([string]$taskInfo.version + '.' + [string]$taskInfo.build) -ne $taskBuild) { throw 'The published manifest is for another build.' }
    $taskTarget = [IO.Path]::GetFullPath($Output)
    New-Item -ItemType Directory -Path (Split-Path $taskTarget -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $taskManifest -Destination $taskTarget -Force
    Write-Output ('Patch base: ' + $taskBuild + ' (' + $Architecture + ')')
    Write-Output $taskTarget
}
finally { Remove-Item -LiteralPath $taskTemporary -Recurse -Force -ErrorAction SilentlyContinue }
