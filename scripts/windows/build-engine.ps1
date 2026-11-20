param([ValidateSet('debug','release')][string]$Configuration = 'debug', [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }),
    [string]$Products)
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
Push-Location $taskRoot
try {
    $taskBinary = $null
    if ($Products) {
        $taskBinary = python -S scripts/windows/stage-engine.py --restore $Products --architecture $Architecture --configuration $Configuration
        if ($LASTEXITCODE -ne 0) { throw 'Could not check Windows engine products.' }
    }
    $taskPrebuilt = [bool]$taskBinary
    $taskStage = $null
    if ($taskPrebuilt) {
        Write-Output 'Using verified cached engine and adapter products.'
    } else {
        $taskStage = python -S scripts/windows/stage-engine.py
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Windows source snapshot.' }
        $taskBinary = Join-Path $taskScratchPath ($taskArchitecture.Triple + '/' + $Configuration)
        swift build --build-system native @taskSwiftFlags @taskSwiftTargetFlags --package-path $taskStage --scratch-path $taskScratchPath --configuration $Configuration --product PacerEngine
        if ($LASTEXITCODE -ne 0) { throw 'Windows engine build failed.' }
        if ($Products) {
            & (Join-Path $PSScriptRoot 'build-adapters.ps1') -SourcePath $taskStage -ScratchPath $taskScratchPath -Configuration $Configuration
            python -S scripts/windows/stage-engine.py --save $Products --binary $taskBinary --architecture $Architecture --configuration $Configuration
            if ($LASTEXITCODE -ne 0) { throw 'Could not save Windows engine products.' }
        }
    }
    New-Item -ItemType Directory -Path output/windows -Force | Out-Null
    @{source = $taskStage; scratch = $taskScratchPath; binary = $taskBinary; configuration = $Configuration; architecture = $Architecture; prebuilt = $taskPrebuilt; adapters = [bool]$Products} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path 'output/windows' $taskArchitecture.Receipt) -Encoding utf8
} finally { Pop-Location }
