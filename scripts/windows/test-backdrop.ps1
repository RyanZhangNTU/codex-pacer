param(
    [ValidateSet('Debug','Release')][string]$Configuration = 'Debug',
    [ValidateSet('overlay','cpu','interactive','input','motion','settle')][string]$Mode = 'overlay',
    [string]$Output
)
. (Join-Path $PSScriptRoot 'environment.ps1')
$taskScreens = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(CodexPacer|Pacer.*(BackdropTests|PresentationTests))$'
})
if ($taskScreens.Count) { throw 'Another Pacer screen test is active. Close or coordinate it before continuing.' }
$taskEngine = Join-Path $taskRoot "windows/Desktop/bin/$Configuration/net10.0-windows/Engine/PacerEngine.exe"
if (!(Test-Path -LiteralPath $taskEngine)) { throw 'Build the desktop before running material acceptance.' }
if (!$Output) { $Output = Join-Path $taskRoot ('output/windows/backdrop/' + [guid]::NewGuid().ToString('N')) }
$taskOutput = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $taskOutput) { throw 'Use a fresh output directory for each screen test.' }
New-Item -ItemType Directory -Path $taskOutput | Out-Null
dotnet build (Join-Path $taskRoot 'windows/Tests/BackdropTests/Pacer.BackdropTests.csproj') --configuration $Configuration -warnaserror
if ($LASTEXITCODE -ne 0) { throw 'Material acceptance build failed.' }
$taskExe = Join-Path $taskRoot "windows/Tests/BackdropTests/bin/$Configuration/net10.0-windows10.0.19041.0/win-x64/Pacer.BackdropTests.exe"
$taskProcess = Start-Process -FilePath $taskExe -ArgumentList @($Mode, ('"' + $taskOutput + '"')) -PassThru -WindowStyle Hidden
$taskClock = [Diagnostics.Stopwatch]::StartNew()
$taskLimit = if ($Mode -eq 'cpu') { 420 } elseif ($Mode -eq 'interactive') { 200 } else { 120 }
try {
    while (!$taskProcess.WaitForExit(1000)) {
        if ($taskClock.Elapsed.TotalSeconds -gt $taskLimit) { throw 'Material acceptance exceeded its deadline.' }
    }
    if ($taskProcess.ExitCode -ne 0) {
        $taskFailure = Join-Path $taskOutput 'failure.txt'
        if (Test-Path -LiteralPath $taskFailure) { Get-Content -LiteralPath $taskFailure }
        throw 'Material acceptance failed.'
    }
    if ($Mode -eq 'overlay') {
        python (Join-Path $PSScriptRoot 'check-backdrop-pixels.py') $taskOutput
        if ($LASTEXITCODE -ne 0) { throw 'Pixels changed outside the island contour.' }
    }
    Write-Output $taskOutput
} finally {
    if (!$taskProcess.HasExited) { $taskProcess.Kill($true); $taskProcess.WaitForExit(5000) | Out-Null }
    $taskProcess.Dispose()
}
