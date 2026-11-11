# Exercise the optional patch base without contacting a release or changing network settings.
$ErrorActionPreference = 'Stop'
$taskDirectory = Join-Path ([IO.Path]::GetTempPath()) ('pacer-update-base-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskDirectory | Out-Null
$taskOutput = Join-Path $taskDirectory 'base.json'
$taskFixtureManifest = '{"architecture":"x64","version":"0.0.1","build":"1"}'
$taskDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($taskFixtureManifest))).ToLowerInvariant()
$taskFixtureFeed = @"
<!-- synthetic signature line -->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:pacer="urn:codex-pacer:windows-update"><channel><item>
<sparkle:shortVersionString>0.0.1</sparkle:shortVersionString><sparkle:version>0.0.1.1</sparkle:version>
<enclosure sparkle:os="windows-x64" pacer:manifestSHA256="$taskDigest"/>
</item></channel></rss>
"@
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [int]$MaximumRedirection, [int]$TimeoutSec,
        [int]$MaximumRetryCount, [int]$RetryIntervalSec, [switch]$UseBasicParsing)
    if ($Uri.EndsWith('/appcast-windows.xml')) {
        [IO.File]::WriteAllText($OutFile, $taskFixtureFeed)
    } elseif ($Uri.EndsWith('/Codex-Pacer-0.0.1-windows-x64-manifest.json')) {
        if ($MaximumRetryCount -ne 1 -or $TimeoutSec -ne 30) { throw 'The optional request must have a bounded retry.' }
        if ($taskFixtureMode -eq 'unavailable') {
            throw [System.Net.Http.HttpRequestException]::new('Synthetic gateway timeout', $null, [System.Net.HttpStatusCode]::GatewayTimeout)
        }
        [IO.File]::WriteAllText($OutFile, $(if ($taskFixtureMode -eq 'mismatch') { '{}' } else { $taskFixtureManifest }))
    } else { throw 'Unexpected URL in the synthetic release fixture.' }
}
try {
    $taskScript = Join-Path $PSScriptRoot 'fetch-update-base.ps1'
    $taskFixtureMode = 'unavailable'
    $taskResult = & $taskScript -Output $taskOutput -Architecture x64
    if ((Test-Path -LiteralPath $taskOutput) -or $taskResult -notmatch 'No patch base:') { throw 'A missing optional manifest must leave only the full installer.' }
    $taskFixtureMode = 'mismatch'
    $taskRejected = $false
    try { $null = & $taskScript -Output $taskOutput -Architecture x64 }
    catch { if ($_.Exception.Message -ne 'The published manifest differs from the latest feed.') { throw }; $taskRejected = $true }
    if (!$taskRejected -or (Test-Path -LiteralPath $taskOutput)) { throw 'A manifest with the wrong digest must still be rejected.' }
    $taskFixtureMode = 'success'
    $null = & $taskScript -Output $taskOutput -Architecture x64
    if ([IO.File]::ReadAllText($taskOutput) -cne $taskFixtureManifest) { throw 'The matching manifest was not copied.' }
    Write-Output 'PASS optional patch base: unavailable manifest, rejected digest, and verified manifest'
} finally {
    if (Test-Path -LiteralPath $taskOutput) { Remove-Item -LiteralPath $taskOutput -Force }
    [IO.Directory]::Delete($taskDirectory, $false)
}
