param([string]$Application = '', [string]$OutputDirectory = '', [switch]$SelfContained)
. (Join-Path $PSScriptRoot 'environment.ps1')
if (!$Application) { $Application = Join-Path $taskRoot 'windows/Desktop/bin/Debug/net10.0-windows/CodexPacer.exe' }
$taskApplication = [IO.Path]::GetFullPath($Application)
if (!(Test-Path -LiteralPath $taskApplication -PathType Leaf)) { throw 'Build the desktop before testing its instance activation.' }
$taskOutput = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $taskRoot 'output/windows/instance-activation' }
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
$taskChecks = @()
foreach ($taskLanguage in @('en','zh-Hans')) {
    foreach ($taskAction in @('show','hidden','settings')) {
        $taskScope = [Guid]::NewGuid()
        $taskName = $taskLanguage + '-' + $taskAction
        $taskImage = Join-Path $taskOutput ($taskName + '.png')
        $taskFirst = $null; $taskSecond = $null
        function Start-InstanceQa([bool]$Capture) {
            $taskStart = [Diagnostics.ProcessStartInfo]::new($taskApplication)
            $taskStart.UseShellExecute=$false; $taskStart.CreateNoWindow=$true; $taskStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            $taskStart.RedirectStandardError=$true; $taskStart.RedirectStandardOutput=$true
            if ($SelfContained) {
                $taskStart.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
                foreach ($taskVariable in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_HOST_PATH','DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','PACER_SWIFT_ROOT')) { $taskStart.Environment.Remove($taskVariable)|Out-Null }
                $taskStart.Environment['DOTNET_MULTILEVEL_LOOKUP']='0'
            }
            foreach ($taskArgument in @('--demo','--reference-fixture','--activation-qa',$taskScope.ToString(),'--language',$taskLanguage)) { $taskStart.ArgumentList.Add($taskArgument) }
            if ($Capture) {
                foreach ($taskArgument in @('--collapsed','--capture-preview',$taskImage)) { $taskStart.ArgumentList.Add($taskArgument) }
                if ($taskName -eq 'en-show') {
                    foreach ($taskArgument in @('--activation-startup-delay','3000')) { $taskStart.ArgumentList.Add($taskArgument) }
                }
                if ($taskAction -eq 'hidden') { $taskStart.ArgumentList.Add('--hide-before-activation') }
            } elseif ($taskAction -eq 'settings') { $taskStart.ArgumentList.Add('--settings') }
            return [Diagnostics.Process]::Start($taskStart)
        }
        try {
            $taskStarted = [DateTime]::UtcNow
            $taskFirst = Start-InstanceQa $true
            $taskFirstError = $taskFirst.StandardError.ReadToEndAsync(); $taskFirstOutput = $taskFirst.StandardOutput.ReadToEndAsync()
            $taskReady = $false
            for ($taskAttempt=0; $taskAttempt -lt 100; $taskAttempt++) {
                if ($taskFirst.HasExited) { throw 'The first instance exited before accepting activation.' }
                $taskMutex=$null
                try { $taskMutex=[Threading.Mutex]::OpenExisting('Local\CodexPacer.Windows.QA.' + $taskScope.ToString('N')); $taskReady=$true }
                catch [Threading.WaitHandleCannotBeOpenedException] { }
                finally { if($taskMutex){$taskMutex.Dispose()} }
                if($taskReady){break}; Start-Sleep -Milliseconds 30
            }
            if (!$taskReady) { throw 'The isolated first-instance mutex was not observed.' }
            $taskSecond = Start-InstanceQa $false
            $taskSecondError = $taskSecond.StandardError.ReadToEndAsync(); $taskSecondOutput = $taskSecond.StandardOutput.ReadToEndAsync()
            if (!$taskSecond.WaitForExit(10000)) { throw 'The second instance did not hand off its activation.' }
            if ($taskSecond.ExitCode -ne 0) { throw ('The second instance failed (' + $taskName + ', exit ' + $taskSecond.ExitCode + '): ' + $taskSecondError.GetAwaiter().GetResult()) }
            if (!$taskFirst.WaitForExit(25000)) { throw 'The first instance did not complete the activated capture.' }
            if ($taskFirst.ExitCode -ne 0 -or !(Test-Path -LiteralPath $taskImage) -or (Get-Item -LiteralPath $taskImage).LastWriteTimeUtc -lt $taskStarted) {
                throw ('The activated capture failed: ' + $taskFirstError.GetAwaiter().GetResult())
            }
            $taskMetadata = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($taskImage,'.json')) -Raw | ConvertFrom-Json
            $taskReceipt = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($taskImage,'.activation.json')) -Raw | ConvertFrom-Json
            if ($taskReceipt.receiver -ne $taskFirst.Id -or $taskReceipt.wasExpanded) { throw 'The actual first process did not receive activation from its initial collapsed state.' }
            if ($taskAction -eq 'hidden' -and $taskReceipt.wasVisible) { throw 'The hidden-window fixture was visible before activation.' }
            if ($taskAction -eq 'settings' -and !$taskReceipt.settingsVisible) { throw 'The native request did not directly open Settings.' }
            if ($taskAction -ne 'settings' -and (!$taskReceipt.visible -or !$taskReceipt.expanded)) { throw 'The native request did not directly reveal the island.' }
            if ($taskAction -ne 'settings' -and (!$taskMetadata.expanded -or !$taskMetadata.windowVisible)) { throw 'A second launch did not reveal the existing island.' }
            if ($taskAction -eq 'settings' -and $taskMetadata.pane -ne 'general') { throw 'The Settings activation did not reach the existing Settings window.' }
            $taskChecks += @{language=$taskLanguage;action=$taskAction;receiver=$taskReceipt.receiver;firstExit=$taskFirst.ExitCode;secondExit=$taskSecond.ExitCode;capture=[IO.Path]::GetFileName($taskImage)}
            Write-Output ('PASS actual two-process activation: ' + $taskName)
        } finally {
            foreach ($taskOwned in @($taskSecond,$taskFirst)) {
                if ($taskOwned) { if (!$taskOwned.HasExited) { $taskOwned.Kill($true); $taskOwned.WaitForExit(5000)|Out-Null }; $taskOwned.Dispose() }
            }
        }
    }
}
[IO.File]::WriteAllText((Join-Path $taskOutput 'result.json'),(@{schemaVersion=1;syntheticOnly=$true;isolatedScopes=$true;checks=$taskChecks;result='passed'}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
