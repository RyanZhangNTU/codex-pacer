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
. (Join-Path $PSScriptRoot 'version.ps1')
$taskCurrent = Get-PacerVersion
python -S (Join-Path $PSScriptRoot 'fetch-update-base.py') $Output $Architecture ($taskCurrent.version + '.' + $taskCurrent.build)
if ($LASTEXITCODE -ne 0) { throw 'Could not verify the Windows patch base.' }
