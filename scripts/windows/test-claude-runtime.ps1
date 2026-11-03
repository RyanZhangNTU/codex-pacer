param([ValidateSet('Debug','Release')][string]$Configuration = 'Release')
. (Join-Path $PSScriptRoot 'environment.ps1')
$taskPython = & (Join-Path $PSScriptRoot 'setup-claude-python.ps1')
$taskBundle = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows/Engine')
& (Join-Path $taskPython 'python.exe') -S (Join-Path $PSScriptRoot 'test-claude-runtime.py') --bundle $taskBundle --output (Join-Path $taskRoot 'output/windows/claude-runtime-tests.json')
if ($LASTEXITCODE -ne 0) { throw 'The isolated Claude runtime checks failed.' }
