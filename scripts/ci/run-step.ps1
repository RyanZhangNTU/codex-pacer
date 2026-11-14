param([Parameter(Mandatory=$true)][string]$Step)
$ErrorActionPreference = 'Stop'
. $Step
if (Test-Path variable:LASTEXITCODE) { exit $LASTEXITCODE }
