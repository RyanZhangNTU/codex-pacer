param([ValidateSet('Debug','Release')][string]$Configuration = 'Release')
. (Join-Path $PSScriptRoot 'environment.ps1')
$taskPython = & (Join-Path $PSScriptRoot 'setup-claude-python.ps1')
$taskBundle = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows/Engine')
# Git Bash can drop an elevated parent's administrator token. Start the entire
# per-user fixture there so helper writes and both shell readers share a user.
# Elevated/default-owner behavior is covered separately by Windows Swift tests.
$taskBash = if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $env:CLAUDE_CODE_GIT_BASH_PATH } else { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' }
if (!(Test-Path -LiteralPath $taskBash -PathType Leaf)) { throw 'Git Bash is required for the Windows command contract.' }
& $taskBash --noprofile --norc -c 'exec "$@"' pacer (Join-Path $taskPython 'python.exe').Replace('\','/') -S (Join-Path $PSScriptRoot 'test-claude-runtime.py').Replace('\','/') --bundle $taskBundle.Replace('\','/') --output (Join-Path $taskRoot 'output/windows/claude-runtime-tests.json').Replace('\','/')
if ($LASTEXITCODE -ne 0) { throw 'The isolated Claude runtime checks failed.' }
