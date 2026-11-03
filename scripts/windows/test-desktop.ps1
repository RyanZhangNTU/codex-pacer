param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug')
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'harness-fixture.ps1')
$taskPreviousHarnessFixture = $env:PACER_HARNESS_DESKTOP_FIXTURE
$taskEngine = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows/Engine/PacerEngine.exe')
if (!(Test-Path -LiteralPath $taskEngine)) { throw 'Build the Windows desktop before its integration tests.' }
try {
    $env:PACER_HARNESS_DESKTOP_FIXTURE = Get-HarnessMetadataFixture
    dotnet run --project (Join-Path $taskRoot 'windows/Tests/DesktopTests/Pacer.DesktopTests.csproj') --configuration $Configuration -- $taskEngine
    if ($LASTEXITCODE -ne 0) { throw 'Windows desktop integration tests failed.' }
} finally { $env:PACER_HARNESS_DESKTOP_FIXTURE = $taskPreviousHarnessFixture }
