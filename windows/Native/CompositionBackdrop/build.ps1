param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$taskCompiler = Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue
if (!$taskCompiler) { throw 'Visual C++ x64 tools are required; run build-desktop.ps1 from its configured environment.' }
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
$taskArguments = @('/nologo', '/std:c++17', '/EHsc', '/permissive-', '/W4', '/WX', '/O2', '/MT', '/LD', '/DUNICODE', '/D_UNICODE',
    "/I$taskHeaders", (Join-Path $PSScriptRoot 'Backdrop.cpp'), "/Fo$(Join-Path $taskOutput 'Backdrop.obj')", "/Fe$taskBinary", '/link', "/OUT:$taskBinary",
    "/IMPLIB:$(Join-Path $taskOutput 'PacerCompositionBackdrop.lib')", 'windowsapp.lib', 'CoreMessaging.lib', 'user32.lib', 'gdi32.lib', 'dwmapi.lib', 'd3d11.lib', 'd2d1.lib', 'dxguid.lib', 'ole32.lib', 'uiautomationcore.lib')
& $taskCompiler.Source @taskArguments
if ($LASTEXITCODE -ne 0) { throw 'Composition surface build failed.' }
