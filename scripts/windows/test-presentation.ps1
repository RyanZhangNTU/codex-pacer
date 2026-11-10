param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug', [ValidateSet('all','island','settings','collapsed','panel','quota','web','connection','host','harness','conversation','responsive','idle','quotaIdle','recovery','persistence','deepseek','display','displaySettings','position','pages','accessibility','ssh','updates','progress')][string[]]$Group = @('all'))
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
. (Join-Path $PSScriptRoot 'harness-fixture.ps1')
$taskPreviousFixture = $env:PACER_HARNESS_DESKTOP_FIXTURE
Push-Location $taskRoot
try {
    $env:PACER_HARNESS_DESKTOP_FIXTURE = Get-HarnessMetadataFixture
    $taskVersion = Get-PacerVersion
    dotnet build windows/Tests/PresentationTests/Pacer.PresentationTests.csproj --configuration $Configuration -warnaserror "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'Presentation test build failed.' }
    $taskOutput = Join-Path $taskRoot 'output/windows/presentation'
    $taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows/CodexPacer.exe')
    dotnet run --no-build --project windows/Tests/PresentationTests/Pacer.PresentationTests.csproj --configuration $Configuration -- $taskOutput ($Group -join ',') $taskDesktop
    if ($LASTEXITCODE -ne 0) { throw 'Functional presentation tests failed.' }
} finally { $env:PACER_HARNESS_DESKTOP_FIXTURE = $taskPreviousFixture; Pop-Location }
