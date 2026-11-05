param([ValidateSet('debug','release')][string]$Configuration = 'debug', [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }),
    # CI: a directory of engine products saved by build-desktop.ps1 -SaveEngineProducts. They are used
    # only when they were built from this exact source snapshot; otherwise the engine is compiled.
    [string]$Products)
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
Push-Location $taskRoot
try {
    $taskStage = & python -S scripts/windows/stage-engine.py
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Windows source snapshot.' }
    $taskBinary = Join-Path $taskScratchPath ($taskArchitecture.Triple + '/' + $Configuration)
    $taskPrebuilt = $false
    if ($Products -and (Test-Path -LiteralPath (Join-Path $Products 'products.json'))) {
        $taskProducts = Get-Content -LiteralPath (Join-Path $Products 'products.json') -Raw | ConvertFrom-Json
        $taskPrebuilt = $taskProducts.source -eq (Split-Path $taskStage -Leaf) -and $taskProducts.configuration -eq $Configuration -and $taskProducts.architecture -eq $Architecture
    }
    if ($taskPrebuilt) {
        New-Item -ItemType Directory -Path $taskBinary -Force | Out-Null
        Get-ChildItem -LiteralPath $Products | Where-Object Name -ne 'products.json' | Copy-Item -Destination $taskBinary -Recurse -Force
        Write-Output ('Using the engine products of source snapshot ' + (Split-Path $taskStage -Leaf) + '.')
    } else {
        swift build --build-system native @taskSwiftFlags @taskSwiftTargetFlags --package-path $taskStage --scratch-path $taskScratchPath --configuration $Configuration --product PacerEngine
        if ($LASTEXITCODE -ne 0) { throw 'Windows engine build failed.' }
    }
    New-Item -ItemType Directory -Path output/windows -Force | Out-Null
    @{source = $taskStage; scratch = $taskScratchPath; configuration = $Configuration; architecture = $Architecture; prebuilt = $taskPrebuilt} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path 'output/windows' $taskArchitecture.Receipt) -Encoding utf8
} finally { Pop-Location }
