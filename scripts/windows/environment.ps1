$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
function Set-PacerEnvironmentPrefix([string]$Name, [string[]]$Entries) {
    $taskExisting = [Environment]::GetEnvironmentVariable($Name, 'Process')
    $taskSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $taskOrdered = [Collections.Generic.List[string]]::new()
    foreach ($taskEntry in @($Entries) + @($taskExisting -split ';')) {
        if ([string]::IsNullOrWhiteSpace($taskEntry)) { continue }
        $taskKey = $taskEntry.Trim().Trim('"').TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($taskSeen.Add($taskKey)) { $taskOrdered.Add($taskEntry) }
    }
    [Environment]::SetEnvironmentVariable($Name, ($taskOrdered -join ';'), 'Process')
}
$taskVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (Test-Path -LiteralPath $taskVsWhere) {
    $taskVs = & $taskVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $taskVsReady = $taskVs -and $env:VSINSTALLDIR -and
        [string]::Equals($taskVs.TrimEnd('\'), $env:VSINSTALLDIR.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and
        $env:VSCMD_ARG_TGT_ARCH -eq 'x64' -and $env:VSCMD_ARG_HOST_ARCH -eq 'x64' -and
        [bool](Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($taskVs -and !$taskVsReady) {
        Import-Module (Join-Path $taskVs 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
        Enter-VsDevShell -VsInstallPath $taskVs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    }
}
$taskRuntime = $null
$taskSwiftRoot = if ($env:PACER_SWIFT_ROOT) { $env:PACER_SWIFT_ROOT } else { Join-Path $taskRoot 'output/toolchains/swift' }
if (Test-Path -LiteralPath $taskSwiftRoot) {
    $taskToolchain = Get-ChildItem -LiteralPath (Join-Path $taskSwiftRoot 'Toolchains') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $taskPlatform = Get-ChildItem -LiteralPath (Join-Path $taskSwiftRoot 'Platforms') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $taskRuntime = Get-ChildItem -LiteralPath (Join-Path $taskSwiftRoot 'Runtimes') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    Set-PacerEnvironmentPrefix 'Path' @((Join-Path $taskToolchain.FullName 'usr/bin'), (Join-Path $taskRuntime.FullName 'usr/bin'))
    $env:SDKROOT = Join-Path $taskPlatform.FullName 'Windows.platform/Developer/SDKs/Windows.sdk'
}
# A workspace SDK can be used without installing or replacing the system SDK.
$taskSdk = Join-Path $taskRoot 'output/toolchains/microsoft.windows.sdk.cpp/c'
$taskSdkLibraries = Join-Path $taskRoot 'output/toolchains/microsoft.windows.sdk.cpp.x64/c'
$taskSwiftFlags = @()
if (Test-Path -LiteralPath $taskSdk) {
    $taskSdkVersion = Get-ChildItem -LiteralPath (Join-Path $taskSdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $taskIncludes = @('ucrt','shared','um','winrt','cppwinrt') | ForEach-Object { Join-Path $taskSdkVersion.FullName $_ }
    Set-PacerEnvironmentPrefix 'INCLUDE' $taskIncludes
    Set-PacerEnvironmentPrefix 'LIB' @((Join-Path $taskSdkLibraries 'ucrt/x64'), (Join-Path $taskSdkLibraries 'um/x64'))
    $env:WindowsSdkDir = $taskSdk + '\'
    $env:WindowsSDKVersion = $taskSdkVersion.Name + '\'
    $env:UniversalCRTSdkDir = $taskSdk + '\'
    $env:UCRTVersion = $taskSdkVersion.Name
    $taskSwiftFlags = @('-Xbuild-tools-swiftc','-windows-sdk-root','-Xbuild-tools-swiftc',$taskSdk,
        '-Xbuild-tools-swiftc','-windows-sdk-version','-Xbuild-tools-swiftc',$taskSdkVersion.Name,
        '-Xswiftc','-windows-sdk-root','-Xswiftc',$taskSdk,
        '-Xswiftc','-windows-sdk-version','-Xswiftc',$taskSdkVersion.Name)
    foreach ($taskInclude in $taskIncludes) {
        $taskIncludeFlag = '-I' + $taskInclude
        $taskSwiftFlags += @('-Xcc', $taskIncludeFlag, '-Xswiftc', '-Xcc', '-Xswiftc', $taskIncludeFlag,
            '-Xbuild-tools-swiftc', '-Xcc', '-Xbuild-tools-swiftc', $taskIncludeFlag)
    }
}
# Match the pinned SDK's ownership of Clang builtin typedefs (not SwiftShims).
$taskSwiftFlags += @('-Xswiftc','-Xcc','-Xswiftc','-fno-builtin-headers-in-system-modules',
    '-Xbuild-tools-swiftc','-Xcc','-Xbuild-tools-swiftc','-fno-builtin-headers-in-system-modules')
$taskDotnet = Join-Path $taskRoot 'output/toolchains/dotnet'
if (Test-Path -LiteralPath (Join-Path $taskDotnet 'dotnet.exe')) {
    Set-PacerEnvironmentPrefix 'Path' @($taskDotnet)
    $env:DOTNET_ROOT = $taskDotnet
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_HOME = Join-Path $taskRoot 'output/dotnet-home'
$env:NUGET_PACKAGES = Join-Path $taskRoot 'output/nuget-packages'

# Sources are immutable snapshots; dependencies and object files reuse one isolated cache.
$taskScratchPath = Join-Path ([IO.Path]::GetTempPath()) 'codex-pacer-windows/build-6.4.2-x64'
