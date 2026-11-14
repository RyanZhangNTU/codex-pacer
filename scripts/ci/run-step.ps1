param([Parameter(Mandatory=$true)][string]$Step)
$ErrorActionPreference = 'Stop'
# GitHub chooses the temporary file extension from the outer custom shell
# (Python), so execute its contents as PowerShell instead of its association.
& ([scriptblock]::Create([IO.File]::ReadAllText($Step)))
if (Test-Path variable:LASTEXITCODE) { exit $LASTEXITCODE }
