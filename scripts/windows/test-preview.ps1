param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$taskArchive = [IO.Path]::GetFullPath($Archive)
$taskArchiveHash = (Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$taskWork = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('Codex Pacer 预览 ' + [Guid]::NewGuid().ToString('N'))))
$taskExpectedWork = $taskWork
$taskApp = Join-Path $taskWork '应用'
$taskUnrelated = Join-Path $taskWork '工作目录'
$taskOutput = Join-Path $taskRoot ('output/windows/preview-checks/' + [IO.Path]::GetFileNameWithoutExtension($taskArchive))
New-Item -ItemType Directory -Path $taskApp,$taskUnrelated,$taskOutput -Force | Out-Null
$taskChecks = @()

function New-PacerPreviewProcess([string]$Executable) {
    $taskStart = [Diagnostics.ProcessStartInfo]::new($Executable)
    $taskStart.UseShellExecute=$false; $taskStart.CreateNoWindow=$true; $taskStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $taskStart.WorkingDirectory=$taskUnrelated; $taskStart.RedirectStandardError=$true; $taskStart.RedirectStandardOutput=$true
    $taskStart.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
    foreach ($taskVariable in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_ROOT_ARM64','DOTNET_HOST_PATH','DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','PACER_SWIFT_ROOT')) {
        $taskStart.Environment.Remove($taskVariable) | Out-Null
    }
    $taskStart.Environment['DOTNET_MULTILEVEL_LOOKUP']='0'
    return $taskStart
}

function Test-PacerPreviewEngine {
    $taskStart = New-PacerPreviewProcess (Join-Path $taskApp 'Engine/PacerEngine.exe')
    $taskStart.RedirectStandardInput = $true
    $taskStart.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($taskArgument in @('--demo','--reference-fixture','--language','en')) { $taskStart.ArgumentList.Add($taskArgument) }
    $taskEngine = [Diagnostics.Process]::Start($taskStart)
    try {
        $taskErrors = $taskEngine.StandardError.ReadToEndAsync()
        function Wait-PacerFrame([string]$Type, [string]$Id = '') {
            $taskDeadline = [Diagnostics.Stopwatch]::StartNew()
            do {
                $taskRemaining = [TimeSpan]::FromSeconds(15) - $taskDeadline.Elapsed
                if ($taskRemaining.Ticks -le 0) { throw "No $Type frame from the packaged engine." }
                $taskLine = $taskEngine.StandardOutput.ReadLineAsync().WaitAsync($taskRemaining).GetAwaiter().GetResult()
                if ($null -eq $taskLine) { throw "The packaged engine closed before its $Type frame." }
                $taskFrame = $taskLine | ConvertFrom-Json
                if ($taskFrame.type -eq 'error') { throw "The packaged engine reported a protocol error." }
            } until ($taskFrame.type -eq $Type -and (!$Id -or $taskFrame.id -eq $Id))
            return $taskFrame
        }
        if ((Wait-PacerFrame 'hello').protocolVersion -ne 1) { throw 'The packaged engine reported an incompatible protocol.' }
        foreach ($taskMethod in @('initialize','shutdown')) {
            $taskEngine.StandardInput.WriteLine(('{{"protocolVersion":1,"id":"{0}","method":"{0}"}}' -f $taskMethod))
            $taskEngine.StandardInput.Flush()
            if (!(Wait-PacerFrame 'result' $taskMethod).ok) { throw "The packaged engine rejected $taskMethod." }
        }
        if (!$taskEngine.WaitForExit(5000) -or $taskEngine.ExitCode -ne 0) { throw 'The packaged engine did not exit successfully.' }
        Write-Output 'PASS extracted engine: hello, initialize, shutdown and clean exit with the developer PATH removed.'
    } catch {
        if ($taskEngine.HasExited) { Write-Host ('Packaged ARM64 engine exit code: ' + $taskEngine.ExitCode) }
        throw
    } finally {
        if (!$taskEngine.HasExited) { $taskEngine.Kill($true); $taskEngine.WaitForExit(5000) | Out-Null }
        $taskEngine.Dispose()
    }
}

function Write-PacerPreviewDiagnostics([string]$ErrorText) {
    $ErrorText -split "\r?\n" | Where-Object { $_ -match '^Pacer preview: ' } | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
}

try {
    [IO.Compression.ZipFile]::ExtractToDirectory($taskArchive, $taskApp)
    $taskManifest = Get-Content -LiteralPath (Join-Path $taskApp 'build-info.json') -Raw | ConvertFrom-Json
    if ($taskManifest.schemaVersion -ne 1 -or $taskManifest.architecture -notin @('x64','arm64')) { throw 'Unexpected preview manifest.' }
    if ($taskManifest.architecture -eq 'arm64' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') { throw 'Runtime preview acceptance requires an ARM64 Windows host for this payload.' }
    $taskPrefix = $taskApp.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($taskFile in $taskManifest.files) {
        $taskPath = [IO.Path]::GetFullPath((Join-Path $taskApp $taskFile.path))
        if (!$taskPath.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskFile.sha256) { throw 'A packaged file differs from its recorded hash.' }
    }
    if ($taskManifest.architecture -eq 'arm64') { Test-PacerPreviewEngine }
    $taskCaptureTimeout = if ($taskManifest.architecture -eq 'arm64') { 60000 } else { 30000 }
    foreach ($taskLanguage in @('en','zh-Hans')) {
        foreach ($taskScene in @('island','settings','claude-settings')) {
            $taskImage = Join-Path $taskOutput ($taskLanguage + '-' + $taskScene + '.png')
            $taskStart = New-PacerPreviewProcess (Join-Path $taskApp 'CodexPacer.exe')
            foreach ($taskArgument in @('--demo','--reference-fixture','--language',$taskLanguage,'--capture-preview',$taskImage)) { $taskStart.ArgumentList.Add($taskArgument) }
            if ($taskScene -ne 'island') {
                $taskPane = if ($taskScene -eq 'claude-settings') { 'claude' } else { 'deepseek' }
                foreach ($taskArgument in @('--settings-preview','--settings-pane',$taskPane)) { $taskStart.ArgumentList.Add($taskArgument) }
            }
            $taskProcess = [Diagnostics.Process]::Start($taskStart)
            try {
                $taskErrors = $taskProcess.StandardError.ReadToEndAsync(); $taskStdout = $taskProcess.StandardOutput.ReadToEndAsync()
                if (!$taskProcess.WaitForExit($taskCaptureTimeout)) {
                    $taskProcess.Kill($true)
                    if ($taskProcess.WaitForExit(5000) -and $taskErrors.Wait(2000)) { Write-PacerPreviewDiagnostics ($taskErrors.GetAwaiter().GetResult()) }
                    throw "The extracted preview did not finish for $taskLanguage/$taskScene within $($taskCaptureTimeout / 1000) seconds."
                }
                $taskErrorText = $taskErrors.GetAwaiter().GetResult(); $null = $taskStdout.GetAwaiter().GetResult()
                if ($taskProcess.ExitCode -ne 0 -or !(Test-Path -LiteralPath $taskImage)) {
                    Write-PacerPreviewDiagnostics $taskErrorText
                    throw ('The extracted preview failed: ' + $taskLanguage + '/' + $taskScene + ', exit ' + $taskProcess.ExitCode)
                }
                if ($taskScene -ne 'island') {
                    $taskCapture = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($taskImage, '.json')) -Raw | ConvertFrom-Json
                    if ($taskCapture.pane -ne $taskPane -or $taskCapture.sourceInspectionPending) { throw 'The extracted source Settings page did not finish its inspection.' }
                }
                $taskChecks += @{language=$taskLanguage;scene=$taskScene;exitCode=$taskProcess.ExitCode;image=[IO.Path]::GetFileName($taskImage)}
            } finally { $taskProcess.Dispose() }
        }
    }
    & (Join-Path $PSScriptRoot 'test-instance-activation.ps1') -Application (Join-Path $taskApp 'CodexPacer.exe') -OutputDirectory (Join-Path $taskOutput 'activation') -SelfContained
    $taskOS = Get-CimInstance Win32_OperatingSystem
    $taskResult = @{schemaVersion=1;archiveSHA256=$taskArchiveHash;sourceCommit=$taskManifest.sourceCommit;sourceDirty=$taskManifest.sourceDirty;
        windows=@{caption=$taskOS.Caption;version=$taskOS.Version;build=$taskOS.BuildNumber};sanitizedDeveloperEnvironment=$true;
        extractedUnicodePath=$true;unrelatedWorkingDirectory=$true;syntheticOnly=$true;twoProcessActivation=$true;checks=$taskChecks;result='passed'}
    [IO.File]::WriteAllText((Join-Path $taskOutput 'result.json'),($taskResult|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Output 'PASS extracted self-contained preview: EN/ZH island, DeepSeek and Claude Settings, no developer PATH, Unicode paths, packaged hashes and graceful exit.'
} finally {
    $taskResolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $taskWork).ProviderPath)
    if ($taskResolved -ne $taskExpectedWork -or (Get-Item -LiteralPath $taskResolved -Force).LinkType) { throw 'Unexpected preview cleanup directory.' }
    Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
