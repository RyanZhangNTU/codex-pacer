param([ValidateSet('debug','release')][string]$Configuration = 'debug')
. (Join-Path $PSScriptRoot 'environment.ps1')
Push-Location $taskRoot
try {
    $taskStage = & python -S scripts/windows/stage-engine.py
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Windows source snapshot.' }
    swift build --build-system native @taskSwiftFlags --package-path $taskStage --scratch-path $taskScratchPath --configuration $Configuration --product PacerEngine
    if ($LASTEXITCODE -ne 0) { throw 'Windows engine build failed.' }
    New-Item -ItemType Directory -Path output/windows -Force | Out-Null
    @{source = $taskStage; scratch = $taskScratchPath; configuration = $Configuration} | ConvertTo-Json | Set-Content -LiteralPath output/windows/engine-location.json -Encoding utf8
} finally { Pop-Location }
