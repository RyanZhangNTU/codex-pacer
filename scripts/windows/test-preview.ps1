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
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($taskArchive, $taskApp)
    $taskManifest = Get-Content -LiteralPath (Join-Path $taskApp 'build-info.json') -Raw | ConvertFrom-Json
    if ($taskManifest.schemaVersion -ne 1 -or $taskManifest.architecture -ne 'x64') { throw 'Unexpected preview manifest.' }
    $taskPrefix = $taskApp.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($taskFile in $taskManifest.files) {
        $taskPath = [IO.Path]::GetFullPath((Join-Path $taskApp $taskFile.path))
        if (!$taskPath.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskFile.sha256) { throw 'A packaged file differs from its recorded hash.' }
    }
    foreach ($taskLanguage in @('en','zh-Hans')) {
        foreach ($taskScene in @('island','settings','claude-settings')) {
            $taskImage = Join-Path $taskOutput ($taskLanguage + '-' + $taskScene + '.png')
            $taskStart = [Diagnostics.ProcessStartInfo]::new((Join-Path $taskApp 'CodexPacer.exe'))
            $taskStart.UseShellExecute=$false; $taskStart.CreateNoWindow=$true; $taskStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            $taskStart.WorkingDirectory=$taskUnrelated; $taskStart.RedirectStandardError=$true; $taskStart.RedirectStandardOutput=$true
            $taskStart.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
            foreach ($taskVariable in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_HOST_PATH','DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','PACER_SWIFT_ROOT')) { $taskStart.Environment.Remove($taskVariable) | Out-Null }
            $taskStart.Environment['DOTNET_MULTILEVEL_LOOKUP']='0'
            foreach ($taskArgument in @('--demo','--reference-fixture','--language',$taskLanguage,'--capture-preview',$taskImage)) { $taskStart.ArgumentList.Add($taskArgument) }
            if ($taskScene -ne 'island') {
                $taskPane = if ($taskScene -eq 'claude-settings') { 'claude' } else { 'deepseek' }
                foreach ($taskArgument in @('--settings-preview','--settings-pane',$taskPane)) { $taskStart.ArgumentList.Add($taskArgument) }
            }
            $taskProcess = [Diagnostics.Process]::Start($taskStart)
            try {
                $taskErrors = $taskProcess.StandardError.ReadToEndAsync(); $taskStdout = $taskProcess.StandardOutput.ReadToEndAsync()
                if (!$taskProcess.WaitForExit(30000)) { $taskProcess.Kill($true); throw 'The extracted preview exceeded its startup deadline.' }
                $taskErrorText = $taskErrors.GetAwaiter().GetResult(); $null = $taskStdout.GetAwaiter().GetResult()
                if ($taskProcess.ExitCode -ne 0 -or !(Test-Path -LiteralPath $taskImage)) {
                    [IO.File]::WriteAllText(($taskImage + '.error.txt'),$taskErrorText)
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
