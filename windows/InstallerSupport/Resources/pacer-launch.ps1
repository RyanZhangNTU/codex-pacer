param([Parameter(Mandatory)][string]$Python, [ValidateSet('no-site','site')][string]$PythonSite,
      [Parameter(Mandatory)][string]$Script, [ValidateSet('hook','statusline')][string]$Mode,
      [Parameter(Mandatory)][string]$ClaudeHome)
$ErrorActionPreference = 'Stop'
$taskProcess = $null
try {
    $taskInfo = [Diagnostics.ProcessStartInfo]::new($Python)
    $taskInfo.UseShellExecute = $false
    $taskInfo.CreateNoWindow = $true
    $taskInfo.RedirectStandardInput = $true
    $taskInfo.RedirectStandardOutput = $true
    $taskInfo.RedirectStandardError = $true
    $taskArguments = @()
    if ($PythonSite -eq 'no-site') { $taskArguments += '-S' }
    $taskArguments += @($Script, $Mode, $ClaudeHome)
    $taskInfo.Arguments = ($taskArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $taskProcess = [Diagnostics.Process]::Start($taskInfo)
    # Copy bytes directly; PowerShell's native pipeline can recode a user's
    # existing status-line output or Claude's UTF-8 input.
    $taskOutput = $taskProcess.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
    $taskError = $taskProcess.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
    try { [Console]::OpenStandardInput().CopyTo($taskProcess.StandardInput.BaseStream) }
    catch [IO.IOException] {
        # The shared program closes stdin after its byte limit. Keep its exit
        # code instead of turning that deliberate rejection into a hook error.
    }
    finally { $taskProcess.StandardInput.Close() }
    $taskProcess.WaitForExit()
    $null = $taskOutput.GetAwaiter().GetResult()
    $null = $taskError.GetAwaiter().GetResult()
    exit $taskProcess.ExitCode
} catch { exit 1 }
finally { if ($null -ne $taskProcess) { $taskProcess.Dispose() } }
