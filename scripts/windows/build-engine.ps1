param([ValidateSet('debug','release')][string]$Configuration = 'debug', [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }))
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
Push-Location $taskRoot
try {
    $taskStage = & python -S scripts/windows/stage-engine.py
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Windows source snapshot.' }
    swift build --build-system native @taskSwiftFlags @taskSwiftTargetFlags --package-path $taskStage --scratch-path $taskScratchPath --configuration $Configuration --product PacerEngine
    if ($LASTEXITCODE -ne 0) { throw 'Windows engine build failed.' }
    New-Item -ItemType Directory -Path output/windows -Force | Out-Null
    @{source = $taskStage; scratch = $taskScratchPath; configuration = $Configuration; architecture = $Architecture} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path 'output/windows' $taskArchitecture.Receipt) -Encoding utf8
} finally { Pop-Location }
