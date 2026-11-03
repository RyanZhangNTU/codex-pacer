param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [int]$ProtectedProcessId = 0
)
. (Join-Path $PSScriptRoot 'environment.ps1')
$ErrorActionPreference = 'Stop'
$taskScope = [Guid]::NewGuid().ToString('N')
$taskFixture = Join-Path $taskRoot ('out/pacer-install-check-' + $taskScope.Substring(0,8))
$taskApp = [IO.Path]::GetFullPath((Join-Path $taskFixture '中文 空格/应用'))
$taskData = Join-Path (Split-Path $taskApp -Parent) ('CodexPacer-QA-' + $taskScope)
$taskStartupName = 'CodexPacer.QA.' + $taskScope
$taskInstallKey = 'Software\CodexPacer\Installations\' + $taskScope
$taskArpKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexPacer.Windows.QA.' + $taskScope + '_is1'
$taskRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$taskApprovalKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$taskShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) ('Codex Pacer QA ' + $taskScope + '/Codex Pacer.lnk')
$taskPreviousBundleCache = $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $taskFixture 'bundle-cache'
New-Item -ItemType Directory -Path $taskFixture -Force | Out-Null
$taskProtected = if ($ProtectedProcessId -gt 0) { Get-Process -Id $ProtectedProcessId -ErrorAction SilentlyContinue } else { $null }
$taskProtectedStart = if ($taskProtected) { $taskProtected.StartTime } else { $null }
$taskPasses = [Collections.Generic.List[string]]::new()
$taskDemo = $null
$taskUninstalled = $false
$taskNotificationApp = $null
$taskNotificationClass = $null
$taskFailure = $null

function Assert-Pacer([bool]$Value, [string]$Message) {
    if (!$Value) { throw $Message }
}
function Record-Pacer([string]$Name) { $taskPasses.Add($Name); Write-Output ('PASS ' + $Name) }
function Invoke-PacerTestProcess([string]$File, [string[]]$Arguments, [int[]]$Expected = @(0), [switch]$Offline, [string]$StdinJson = $null) {
    $taskStart = [Diagnostics.ProcessStartInfo]::new($File)
    $taskStart.UseShellExecute = $false
    $taskStart.CreateNoWindow = $true
    $taskStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $taskStart.RedirectStandardOutput = $true
    $taskStart.RedirectStandardError = $true
    $taskStart.RedirectStandardInput = ![string]::IsNullOrEmpty($StdinJson)
    foreach ($taskArgument in $Arguments) { $taskStart.ArgumentList.Add($taskArgument) }
    if ($Offline) {
        $taskStart.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
        $taskStart.Environment['DOTNET_ROOT'] = Join-Path $taskFixture 'no-sdk'
        $taskStart.Environment['HTTP_PROXY'] = 'http://127.0.0.1:1'
        $taskStart.Environment['HTTPS_PROXY'] = 'http://127.0.0.1:1'
    }
    $taskProcess = [Diagnostics.Process]::Start($taskStart)
    try {
        if ($taskStart.RedirectStandardInput) { $taskProcess.StandardInput.WriteLine($StdinJson); $taskProcess.StandardInput.Close() }
        $taskOut = $taskProcess.StandardOutput.ReadToEndAsync()
        $taskErr = $taskProcess.StandardError.ReadToEndAsync()
        $taskFinished = $false
        for ($taskAttempt = 0; $taskAttempt -lt 3; $taskAttempt++) {
            if ($taskProcess.WaitForExit(60000)) { $taskFinished = $true; break }
            Write-Host 'Waiting for the owned installer test process.'
        }
        if (!$taskFinished) { $taskProcess.Kill($true); throw 'An owned installer test process exceeded three minutes.' }
        $taskText = $taskOut.GetAwaiter().GetResult()
        $taskErrorText = $taskErr.GetAwaiter().GetResult()
        if ($Expected -notcontains $taskProcess.ExitCode) { throw ('An installer test process returned ' + $taskProcess.ExitCode + '. Diagnostics were retained privately, not forwarded.') }
        Assert-Pacer ($taskText.Length -lt 16384 -and $taskErrorText.Length -lt 16384) 'The maintenance response exceeded its limit.'
        $taskLogFlag = $Arguments | Where-Object { $_.StartsWith('/LOG=', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($taskLogFlag) {
            # Inno's outer launcher can exit just before its worker closes the
            # log. Wait for that worker before reading/asserting or cleanup.
            $taskLogPath = $taskLogFlag.Substring(5)
            $taskLogClosed = $false
            $taskLogDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ($taskLogDeadline.Elapsed.TotalSeconds -lt 10) {
                try {
                    $taskLogFile = [IO.File]::Open($taskLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                    $taskLogFile.Dispose(); $taskLogClosed = $true; break
                } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
            }
            Assert-Pacer $taskLogClosed 'The owned uninstall worker did not close its log in time.'
        }
        return $taskText
    } finally { $taskProcess.Dispose() }
}
function Get-PacerRegistryValue([string]$Path, [string]$Name) {
    $taskKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    try { if ($taskKey) { return $taskKey.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } }
    finally { if ($taskKey) { $taskKey.Dispose() } }
    return $null
}
function Get-PacerOtherSnapshot([string]$Path) {
    $taskValues = @{}
    $taskKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    try {
        if ($taskKey) {
            foreach ($taskName in $taskKey.GetValueNames()) {
                if ($taskName -eq $taskStartupName) { continue }
                $taskRaw = $taskKey.GetValue($taskName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $taskEncoded = [Text.Encoding]::UTF8.GetBytes((@{ kind=$taskKey.GetValueKind($taskName).ToString(); value=$taskRaw } | ConvertTo-Json -Compress))
                $taskValues[$taskName] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($taskEncoded))
            }
        }
    } finally { if ($taskKey) { $taskKey.Dispose() } }
    return $taskValues
}
function Assert-PacerSnapshot([string]$Path, [hashtable]$Before) {
    $taskAfter = Get-PacerOtherSnapshot $Path
    foreach ($taskName in $Before.Keys) { Assert-Pacer ($taskAfter[$taskName] -eq $Before[$taskName]) 'Another startup entry changed during the fixture.' }
}
function Set-PacerApproval([byte]$State) {
    $taskKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($taskApprovalKey)
    try {
        $taskBytes = [byte[]]::new(12); $taskBytes[0] = $State
        $taskKey.SetValue($taskStartupName, $taskBytes, [Microsoft.Win32.RegistryValueKind]::Binary)
    } finally { $taskKey.Dispose() }
}
function Wait-PacerScreen {
    for ($taskMinute = 0; $taskMinute -lt 30; $taskMinute++) {
        $taskBusy = @(Get-Process | Where-Object { $_.ProcessName -match 'BackdropPrototype|route.?b|Pacer\.PresentationTests' })
        if ($taskBusy.Count -eq 0) { return }
        Write-Host 'Another prototype or presentation test is using the desktop; waiting one minute.'
        Start-Sleep -Seconds 60
    }
    throw 'The desktop remained in use for thirty minutes.'
}
function Start-PacerDemo {
    Wait-PacerScreen
    $taskStart = [Diagnostics.ProcessStartInfo]::new((Join-Path $taskApp 'CodexPacer.exe'))
    $taskStart.UseShellExecute = $false; $taskStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($taskArg in @('--demo','--reference-fixture','--activation-qa',$taskScope,'--hide-before-activation','--collapsed')) {
        $taskStart.ArgumentList.Add($taskArg)
    }
    $taskValue = [Diagnostics.Process]::Start($taskStart)
    Start-Sleep -Seconds 3
    Assert-Pacer (!$taskValue.HasExited) 'The installed demo did not stay running.'
    return $taskValue
}
$taskBeforeRun = Get-PacerOtherSnapshot $taskRunKey
$taskBeforeApproval = Get-PacerOtherSnapshot $taskApprovalKey
$taskElevated = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
try {
    & (Join-Path $PSScriptRoot 'package-installer.ps1') -Archive $Archive -QaScope $taskScope
    $taskPackage = Get-Content -LiteralPath (Join-Path $taskRoot 'output/windows/installer-qa-location.json') -Raw | ConvertFrom-Json
    $taskSetup = $taskPackage.installer
    $taskFlags = @('/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/RESTARTEXITCODE=3010',('/DIR=' + $taskApp))
    $null = Invoke-PacerTestProcess $taskSetup $taskFlags
    $taskExe = Join-Path $taskApp 'CodexPacer.exe'
    $taskMaintenance = Join-Path $taskApp 'Maintenance/PacerMaintenance.exe'
    Assert-Pacer ((Test-Path -LiteralPath $taskExe) -and (Test-Path -LiteralPath $taskMaintenance) -and (Test-Path -LiteralPath $taskShortcut)) 'The installed application, maintenance host or Start menu shortcut is missing.'
    Assert-Pacer ((Get-PacerRegistryValue $taskArpKey 'InstallLocation').TrimEnd('\') -eq $taskApp) 'The installer must register its current-user location.'
    $taskMachineKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($taskArpKey)
    try { Assert-Pacer ($null -eq $taskMachineKey) 'A per-user installer cannot register under LocalMachine.' }
    finally { if ($taskMachineKey) { $taskMachineKey.Dispose() } }
    Record-Pacer 'current-user install, Chinese/space path, shortcut, self-contained maintenance and no machine registration'

    New-Item -ItemType Directory -Path $taskData -Force | Out-Null
    $taskPreferences = Join-Path $taskData 'preferences-v1.json'
    $taskReadState = Join-Path $taskData 'completion-dismissals-v1.json'
    [IO.File]::WriteAllText($taskPreferences, '{"schemaVersion":1,"language":"zh-Hans","hideProjects":true}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($taskReadState, ('{"version":1,"digests":["' + ('a' * 64) + '"]}'), [Text.UTF8Encoding]::new($false))
    $taskPreferenceHash = (Get-FileHash -LiteralPath $taskPreferences).Hash
    $taskReadHash = (Get-FileHash -LiteralPath $taskReadState).Hash
    $null = Invoke-PacerTestProcess $taskMaintenance @('startup-enable',$taskScope,$taskApp)
    Assert-Pacer ((Get-PacerRegistryValue $taskRunKey $taskStartupName) -eq ('"' + $taskExe + '" --launch-at-login')) 'Startup must quote the installed executable.'
    $null = Invoke-PacerTestProcess $taskMaintenance @('startup-disable',$taskScope,$taskApp)
    Assert-Pacer ($null -eq (Get-PacerRegistryValue $taskRunKey $taskStartupName)) 'Startup disable must remove the owned Run value.'
    Set-PacerApproval 3
    $null = Invoke-PacerTestProcess $taskMaintenance @('startup-enable',$taskScope,$taskApp)
    $taskStatus = (Invoke-PacerTestProcess $taskMaintenance @('startup-status',$taskScope,$taskApp)) | ConvertFrom-Json
    Assert-Pacer ($taskStatus.Registered -and !$taskStatus.Effective -and $taskStatus.BlockReason -eq 'Disabled') 'The real StartupApproved key must remain disabled after a requested enable.'
    Set-PacerApproval 2
    $taskStatus = (Invoke-PacerTestProcess $taskMaintenance @('startup-status',$taskScope,$taskApp)) | ConvertFrom-Json
    Assert-Pacer ($taskStatus.Effective) 'The enabled approval fixture must read back as effective.'
    Record-Pacer 'live HKCU startup enable/disable and StartupApproved enabled/disabled fixtures; no reboot'

    # Corrupt the installed main assembly. Repair must use Setup's fresh host.
    $taskAssembly = Join-Path $taskApp 'CodexPacer.dll'
    $taskAssemblyHash = (Get-FileHash -LiteralPath $taskAssembly).Hash
    [IO.File]::WriteAllText($taskAssembly, 'synthetic damaged assembly', [Text.UTF8Encoding]::new($false))
    $null = Invoke-PacerTestProcess $taskSetup $taskFlags
    Assert-Pacer ((Get-FileHash -LiteralPath $taskAssembly).Hash -eq $taskAssemblyHash) 'Repair did not restore the damaged host assembly.'
    Record-Pacer 'same-version repair with a damaged installed .NET main assembly'
    $taskLock = [IO.FileStream]::new((Join-Path $taskApp 'Assets/Pacer.ico'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $null = Invoke-PacerTestProcess $taskSetup $taskFlags @(7) }
    finally { $taskLock.Dispose() }
    Assert-Pacer ((Get-FileHash -LiteralPath $taskAssembly).Hash -eq $taskAssemblyHash -and (Test-Path -LiteralPath $taskShortcut)) 'A locked-file preflight changed the installed payload.'
    Record-Pacer 'occupied-file preflight abort preserves installed files and registrations'

    $taskDemo = Start-PacerDemo
    $null = Invoke-PacerTestProcess $taskSetup $taskFlags
    Assert-Pacer ($taskDemo.WaitForExit(10000)) 'Upgrade did not close its own installed demo.'
    $taskDemo.Dispose(); $taskDemo = $null
    Assert-Pacer ((Get-FileHash -LiteralPath $taskPreferences).Hash -eq $taskPreferenceHash -and (Get-FileHash -LiteralPath $taskReadState).Hash -eq $taskReadHash) 'Overinstall changed retained preferences or read state.'
    Assert-Pacer ((Get-PacerRegistryValue $taskRunKey $taskStartupName) -eq ('"' + $taskExe + '" --launch-at-login')) 'Overinstall lost its startup registration.'
    Record-Pacer 'controlled running-app overinstall retains preferences, read state and startup'
    Wait-PacerScreen
    $taskCapture = Join-Path $taskFixture 'offline-demo.png'
    $null = Invoke-PacerTestProcess $taskExe @('--demo','--reference-fixture','--language','zh-Hans','--capture-preview',$taskCapture) -Offline
    Assert-Pacer ((Test-Path -LiteralPath $taskCapture) -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($taskCapture,'.json')))) 'The installed offline demo could not render without SDK PATH.'
    Record-Pacer 'installed offline demo starts without development PATH or DOTNET_ROOT; synthetic capture only'

    $taskClaude = Join-Path $taskData 'claude'
    $taskPacerHooks = Join-Path $taskClaude 'pacer'
    New-Item -ItemType Directory -Path $taskPacerHooks -Force | Out-Null
    $taskOriginal = @{
        hooks=@{ Stop=@(@{ matcher='user'; hooks=@(@{type='command';command='echo synthetic user-hook'}) }) }
        env=@{ USER_SETTING='preserve' }
        statusLine=@{ type='command'; command='echo synthetic user-status'; padding=2 }
        userOption=@{ preserve=$true }
    } | ConvertTo-Json -Depth 12 -Compress
    $taskSettings = $taskOriginal | ConvertFrom-Json -AsHashtable
    $taskHomePosix = $taskClaude.Replace('\','/')
    $taskQuote = [string][char]39
    $taskHook = 'python3 -S ' + $taskQuote + $taskHomePosix + '/pacer/hook.py' + $taskQuote + ' hook ' + $taskQuote + $taskHomePosix + $taskQuote
    $taskSettings.hooks.Stop += @{hooks=@(@{type='command';command=$taskHook})}
    $taskSettings.hooks.UserPromptSubmit = @(@{hooks=@(@{type='command';command=$taskHook.Replace('python3 -S ','python3 ')})})
    $taskSettings.env.CLAUDE_CODE_ENABLE_TELEMETRY = '1'
    $taskSettings.statusLine = @{type='command';command=$taskHook.Replace(' hook ',' statusline ')}
    $taskClaudeSettings = Join-Path $taskClaude 'settings.json'
    [IO.File]::WriteAllText($taskClaudeSettings, ($taskSettings | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $taskPacerHooks 'installation.json'), (@{version=1;addedEnvironment=@{CLAUDE_CODE_ENABLE_TELEMETRY='1'};previousStatusLine=($taskOriginal|ConvertFrom-Json -AsHashtable).statusLine}|ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $taskPacerHooks 'hook.py'), '# synthetic, never executed', [Text.UTF8Encoding]::new($false))
    $taskValidSettings = [IO.File]::ReadAllBytes($taskClaudeSettings)
    $taskManifest = Join-Path $taskPacerHooks 'installation.json'
    $taskValidManifest = [IO.File]::ReadAllBytes($taskManifest)
    $taskInvalidSettings = [Text.Encoding]::UTF8.GetBytes('invalid synthetic account-private task-private')
    [IO.File]::WriteAllBytes($taskClaudeSettings, $taskInvalidSettings)
    $taskUninstaller = Join-Path $taskApp 'unins000.exe'
    $taskFailureLog = Join-Path $taskFixture 'uninstall-failure.log'
    $taskSilent = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG=' + $taskFailureLog))
    $null = Invoke-PacerTestProcess $taskMaintenance @('uninstall',$taskScope,$taskApp) @(21)
    foreach ($taskDecision in @('', 'cancel', 'retry-once')) {
        $taskDecisionFlags = $taskSilent
        if ($taskDecision) { $taskDecisionFlags += '/PACERQAUNINSTALL=' + $taskDecision }
        $null = Invoke-PacerTestProcess $taskUninstaller $taskDecisionFlags @(1)
        Assert-Pacer ((Test-Path -LiteralPath $taskExe) -and (Test-Path -LiteralPath $taskShortcut) -and
            (Get-PacerRegistryValue $taskInstallKey 'Path') -eq $taskApp -and
            $null -ne (Get-PacerRegistryValue $taskArpKey 'DisplayName') -and
            $null -ne (Get-PacerRegistryValue $taskRunKey $taskStartupName)) 'An aborted uninstall changed the application or its registrations.'
        Assert-Pacer ([Convert]::ToBase64String([IO.File]::ReadAllBytes($taskClaudeSettings)) -eq [Convert]::ToBase64String($taskInvalidSettings) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($taskManifest)) -eq [Convert]::ToBase64String($taskValidManifest)) 'Cancel, silent failure or retry changed invalid provider bytes.'
        $taskLogText = [IO.File]::ReadAllText($taskFailureLog)
        Assert-Pacer ($taskLogText.Contains('Claude configuration could not be cleaned') -and
            !$taskLogText.Contains('account-private') -and !$taskLogText.Contains('task-private')) 'The uninstall log lost its safe reason or exposed provider contents.'
        if ($taskDecision -eq 'retry-once') {
            Assert-Pacer (([regex]::Matches($taskLogText, 'Pacer cleanup retry requested\.')).Count -eq 1) 'The QA interactive retry did not use the same cleanup entry exactly once.'
        }
    }
    $taskMaintenanceLog = [IO.File]::ReadAllText((Join-Path $taskData 'uninstall-cleanup.log'))
    Assert-Pacer ($taskMaintenanceLog.Contains('cleanup code 21') -and !$taskMaintenanceLog.Contains('account-private') -and
        !$taskMaintenanceLog.Contains('task-private')) 'Direct silent maintenance must retain a bounded, redacted failure report.'
    Record-Pacer 'invalid Claude JSON: silent abort, interactive cancel and repeated retry preserve installation, registrations and original bytes; safe logs'
    [IO.File]::WriteAllBytes($taskClaudeSettings, $taskValidSettings)
    $taskMapping = 'Software\Classes\AppUserModelId\' + $taskExe.Replace('\','.')
    if (!$taskElevated) {
        $null = Invoke-PacerTestProcess $taskExe @('--qa-register-notifications')
        $taskNotificationApp = Get-PacerRegistryValue $taskMapping 'NotificationGUID'
        Assert-Pacer ($null -ne $taskNotificationApp) 'The owned notification fixture did not register.'
        $taskNotificationClass = Get-PacerRegistryValue ('Software\Classes\AppUserModelId\' + $taskNotificationApp) 'CustomActivator'
    }
    $taskDemo = Start-PacerDemo
    $taskUninstaller = Join-Path $taskApp 'unins000.exe'
    $null = Invoke-PacerTestProcess $taskUninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    Assert-Pacer ($taskDemo.WaitForExit(10000)) 'Uninstall did not close its own demo.'
    $taskDemo.Dispose(); $taskDemo = $null
    $taskUninstalled = $true
    Assert-Pacer (!(Test-Path -LiteralPath $taskExe) -and !(Test-Path -LiteralPath $taskShortcut)) 'Uninstall left its owned application or shortcut.'
    Assert-Pacer ($null -eq (Get-PacerRegistryValue $taskRunKey $taskStartupName) -and $null -eq (Get-PacerRegistryValue $taskApprovalKey $taskStartupName)) 'Uninstall left its owned startup registration.'
    Assert-Pacer ($null -eq (Get-PacerRegistryValue $taskArpKey 'DisplayName') -and $null -eq (Get-PacerRegistryValue $taskInstallKey 'Path')) 'Uninstall left its owned application registrations.'
    $taskActual = [IO.File]::ReadAllText($taskClaudeSettings)
    Assert-Pacer ([Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse($taskOriginal), [Text.Json.Nodes.JsonNode]::Parse($taskActual))) 'Uninstall did not leave exactly the original user hooks, status-line and settings.'
    Assert-Pacer (!(Test-Path -LiteralPath (Join-Path $taskPacerHooks 'installation.json'))) 'Uninstall left its active hook installation manifest.'
    Assert-Pacer ((Get-FileHash -LiteralPath $taskPreferences).Hash -eq $taskPreferenceHash -and (Get-FileHash -LiteralPath $taskReadState).Hash -eq $taskReadHash) 'Uninstall changed retained preferences or read state.'
    if (!$taskElevated) {
        Assert-Pacer ($null -eq (Get-PacerRegistryValue $taskMapping 'NotificationGUID')) 'Uninstall left its notification path mapping.'
        foreach ($taskKeyPath in @(('Software\Classes\AppUserModelId\' + $taskNotificationApp),('Software\Classes\CLSID\' + $taskNotificationClass))) {
            $taskKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($taskKeyPath)
            try { Assert-Pacer ($null -eq $taskKey) 'Uninstall left an owned notification registration.' } finally { if ($taskKey) { $taskKey.Dispose() } }
        }
    }
    Assert-PacerSnapshot $taskRunKey $taskBeforeRun
    Assert-PacerSnapshot $taskApprovalKey $taskBeforeApproval
    if ($taskProtectedStart) {
        $taskStill = Get-Process -Id $ProtectedProcessId -ErrorAction SilentlyContinue
        Assert-Pacer ($taskStill -and $taskStill.StartTime -eq $taskProtectedStart) 'The protected preview process changed during the fixture.'
    }
    Record-Pacer 'uninstall removes owned registrations, shortcut, startup and shared Claude wrappers; user settings and retained data survive'

    # Simulate the interactive Continue choice through a QA-only installer
    # parameter. The production silent path cannot enable this test hook.
    $taskUninstalled = $false
    $null = Invoke-PacerTestProcess $taskSetup $taskFlags
    $null = Invoke-PacerTestProcess $taskMaintenance @('startup-enable',$taskScope,$taskApp)
    [IO.File]::WriteAllBytes($taskClaudeSettings, $taskInvalidSettings)
    [IO.File]::WriteAllBytes($taskManifest, $taskValidManifest)
    $null = Invoke-PacerTestProcess $taskUninstaller ($taskSilent + '/PACERQAUNINSTALL=continue')
    $taskUninstalled = $true
    Assert-Pacer (!(Test-Path -LiteralPath $taskExe) -and !(Test-Path -LiteralPath $taskShortcut) -and
        $null -eq (Get-PacerRegistryValue $taskRunKey $taskStartupName) -and
        $null -eq (Get-PacerRegistryValue $taskApprovalKey $taskStartupName) -and
        $null -eq (Get-PacerRegistryValue $taskArpKey 'DisplayName') -and
        $null -eq (Get-PacerRegistryValue $taskInstallKey 'Path')) 'Continue must remove application files and all cleanable owned registrations.'
    Assert-Pacer ([Convert]::ToBase64String([IO.File]::ReadAllBytes($taskClaudeSettings)) -eq [Convert]::ToBase64String($taskInvalidSettings) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($taskManifest)) -eq [Convert]::ToBase64String($taskValidManifest)) 'Continue cannot change invalid Claude settings or their ownership manifest.'
    $taskLogText = [IO.File]::ReadAllText($taskFailureLog)
    Assert-Pacer ($taskLogText.Contains('Retained Pacer hooks may call a deleted program') -and
        $taskLogText.Contains('settings.json') -and $taskLogText.Contains('previousStatusLine') -and
        !$taskLogText.Contains('account-private') -and !$taskLogText.Contains('task-private')) 'Continue must retain safe manual cleanup instructions and its Claude warning.'
    Assert-PacerSnapshot $taskRunKey $taskBeforeRun
    Assert-PacerSnapshot $taskApprovalKey $taskBeforeApproval
    Record-Pacer 'invalid Claude JSON: explicit interactive Continue removes the app and owned registrations, preserves invalid bytes and records manual cleanup'

    # Exercise the installed runtime and actual application uninstaller, rather
    # than only invoking the hook helper's uninstall entry in isolation.
    $taskUninstalled = $false
    $null = Invoke-PacerTestProcess $taskSetup $taskFlags
    [IO.File]::WriteAllText($taskClaudeSettings, $taskOriginal, [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $taskManifest -Force
    $taskOtherHome = Join-Path $taskData 'Claude 第二个 home'
    New-Item -ItemType Directory -Path $taskOtherHome -Force | Out-Null
    $taskOtherSettings = Join-Path $taskOtherHome 'settings.json'
    [IO.File]::WriteAllText($taskOtherSettings, $taskOriginal, [Text.UTF8Encoding]::new($false))
    $taskRuntime = Join-Path $taskData 'ClaudeRuntime'
    $taskRuntimeHelper = Join-Path $taskApp 'Engine/PacerInstallerHooks.exe'
    foreach ($taskHome in @((Split-Path $taskClaudeSettings -Parent), $taskOtherHome)) {
        $taskSetupResult = Invoke-PacerTestProcess $taskRuntimeHelper @('--ensure',$taskHome,$taskRuntime) -Offline | ConvertFrom-Json
        Assert-Pacer ($taskSetupResult.state -eq 'ready' -and $taskSetupResult.hooksConfigured) 'The installed runtime did not configure its isolated Claude home.'
        Assert-Pacer (!(Test-Path -LiteralPath (Join-Path $taskHome 'pacer/runtime'))) 'A Claude home contains a duplicate runtime.'
    }
    Assert-Pacer (@(Get-ChildItem -LiteralPath $taskRuntime -Directory).Count -eq 1) 'The two homes must share one runtime version.'
    $taskRuntimePython = Join-Path (Get-ChildItem -LiteralPath $taskRuntime -Directory | Select-Object -First 1).FullName 'python.exe'
    $taskPrimaryHome = Split-Path $taskClaudeSettings -Parent
    $null = Invoke-PacerTestProcess $taskRuntimePython @('-S',(Join-Path $taskPrimaryHome 'pacer/hook.py'),'hook',$taskPrimaryHome) -Offline -StdinJson '{"session_id":"fixture-installer","hook_event_name":"UserPromptSubmit","prompt_id":"fixture-prompt","prompt":"SYNTHETIC_PRIVATE_BODY"}'
    $taskSpool = [IO.File]::ReadAllText((Join-Path $taskPrimaryHome 'pacer/events.jsonl'))
    Assert-Pacer (($taskSpool -split "`n" | Where-Object { $_ } | ConvertFrom-Json | Where-Object { $_.kind -eq 'prompt' -and $_.sessionId -eq 'fixture-installer' }).Count -eq 1 -and
        !$taskSpool.Contains('SYNTHETIC_PRIVATE_BODY')) 'The installed offline hook must record its synthetic prompt ownership without its body.'
    $null = Invoke-PacerTestProcess $taskUninstaller $taskSilent
    $taskUninstalled = $true
    Assert-Pacer (!(Test-Path -LiteralPath $taskExe) -and !(Test-Path -LiteralPath $taskRuntime)) 'Actual uninstall left its application or owned shared runtime.'
    foreach ($taskSettingsFile in @($taskClaudeSettings, $taskOtherSettings)) {
        Assert-Pacer ([Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse($taskOriginal),
            [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($taskSettingsFile)))) 'Actual uninstall must leave exactly the user settings in every indexed home.'
    }
    Assert-Pacer ((Get-FileHash -LiteralPath $taskPreferences).Hash -eq $taskPreferenceHash -and (Get-FileHash -LiteralPath $taskReadState).Hash -eq $taskReadHash) 'Runtime cleanup changed retained preferences or read state.'
    Record-Pacer 'installed Python works offline without user Python; actual uninstall restores both indexed Claude homes and deletes the single owned runtime'
    $taskReport = @{ schemaVersion=1; syntheticOnly=$true; elevated=$taskElevated; restarted=$false; checks=@($taskPasses);
        nativeNotificationCleanup=if ($taskElevated) { 'not exercised: elevated CI token' } else { 'passed' }; protectedPreviewUntouched=($null -ne $taskProtectedStart) }
    [IO.File]::WriteAllText((Join-Path $taskRoot 'output/windows/installer-tests.json'), ($taskReport|ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
} catch {
    $taskFailure = $_
    Write-Host ('FAIL installer lifecycle after: ' + ($taskPasses | Select-Object -Last 1))
    throw
} finally {
    if ($taskDemo) {
        if (!$taskDemo.HasExited -and (Test-Path -LiteralPath (Join-Path $taskApp 'Maintenance/PacerMaintenance.exe'))) {
            $null = Invoke-PacerTestProcess (Join-Path $taskApp 'Maintenance/PacerMaintenance.exe') @('prepare',$taskScope,$taskApp,(Join-Path $taskPackage.payload 'build-info.json'))
        }
        $taskDemo.Dispose()
    }
    if (!$taskUninstalled -and (Test-Path -LiteralPath (Join-Path $taskApp 'unins000.exe'))) {
        $null = Invoke-PacerTestProcess (Join-Path $taskApp 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/PACERQAUNINSTALL=continue')
        $taskUninstalled = $true
    }
    $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = $taskPreviousBundleCache
    if ($taskUninstalled) {
        $taskResolved = [IO.Path]::GetFullPath($taskFixture)
        $taskAllowed = [IO.Path]::GetFullPath((Join-Path $taskRoot 'out')).TrimEnd('\') + '\'
        if (!$taskResolved.StartsWith($taskAllowed,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $taskResolved -Leaf).StartsWith('pacer-install-check-')) {
            throw 'The fixture cleanup target is outside its owned workspace.'
        }
        try { Remove-Item -LiteralPath $taskResolved -Recurse -Force }
        catch {
            if (!$taskFailure) { throw }
            Write-Host 'QA fixture cleanup was incomplete; the original check failure is preserved.'
        }
    }
}
