function Get-PacerArchitecture([string]$Architecture = $env:PACER_ARCHITECTURE) {
    if (!$Architecture) { $Architecture = 'x64' }
    if ($Architecture -notin @('x64', 'arm64')) { throw 'PacerArchitecture must be x64 or arm64.' }
    $taskTriple = if ($Architecture -eq 'arm64') { 'aarch64-unknown-windows-msvc' } else { 'x86_64-unknown-windows-msvc' }
    [pscustomobject]@{
        Name = $Architecture; RuntimeIdentifier = 'win-' + $Architecture; Triple = $taskTriple
        DesktopSuffix = if ($Architecture -eq 'x64') { '' } else { '/arm64' }
        Receipt = if ($Architecture -eq 'x64') { 'engine-location.json' } else { 'engine-location-arm64.json' }
    }
}
