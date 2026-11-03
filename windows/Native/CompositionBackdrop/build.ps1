param([Parameter(Mandatory)][string]$OutputDirectory, [ValidateSet('x64','arm64')][string]$Architecture = 'x64')
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot '../../../scripts/windows/environment.ps1')
$ErrorActionPreference = 'Stop'
$taskCompiler = Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue
if (!$taskCompiler -or $env:VSCMD_ARG_TGT_ARCH -ne $Architecture) { throw ('Visual C++ ' + $Architecture + ' tools are required.') }
$taskRoots = @()
if ($env:WindowsSdkDir) { $taskRoots += Join-Path $env:WindowsSdkDir 'Include' }
$taskRoots += Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/Include'
$taskHeaders = @($taskRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'cppwinrt' }
} | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'winrt/Windows.UI.Composition.h') }) | Select-Object -First 1
if (!$taskHeaders) { throw 'The Windows SDK C++/WinRT headers are required.' }
$taskOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
$taskBinary = Join-Path $taskOutput 'PacerCompositionBackdrop.dll'
# New MSVC libraries reject C++/WinRT's experimental C++17 coroutine header.
# VS 2019 19.29 hits a compiler ICE in the SDK's C++20 projection; retain its
# supported C++17 path while VS 2022 and newer use standard C++20 coroutines.
$taskCompilerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($taskCompiler.Source)
$taskStandard = if ($taskCompilerVersion.FileMajorPart -gt 19 -or ($taskCompilerVersion.FileMajorPart -eq 19 -and $taskCompilerVersion.FileMinorPart -ge 30)) { '/std:c++20' } else { '/std:c++17' }
Write-Output ('Composition compiler mode: ' + $taskStandard)
$taskArguments = @('/nologo', $taskStandard, '/EHsc', '/permissive-', '/W4', '/WX', '/O2', '/MT', '/LD', '/DUNICODE', '/D_UNICODE',
    "/I$taskHeaders", (Join-Path $PSScriptRoot 'Backdrop.cpp'), "/Fo$(Join-Path $taskOutput 'Backdrop.obj')", "/Fe$taskBinary", '/link', "/OUT:$taskBinary",
    "/IMPLIB:$(Join-Path $taskOutput 'PacerCompositionBackdrop.lib')", 'windowsapp.lib', 'CoreMessaging.lib', 'user32.lib', 'gdi32.lib', 'dwmapi.lib', 'd3d11.lib', 'd2d1.lib', 'dxguid.lib', 'ole32.lib', 'uiautomationcore.lib')
& $taskCompiler.Source @taskArguments
if ($LASTEXITCODE -ne 0) { throw 'Composition surface build failed.' }
