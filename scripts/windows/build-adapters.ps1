param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$ScratchPath,
    [ValidateSet('debug','release')][string]$Configuration = 'release')
. (Join-Path $PSScriptRoot 'environment.ps1')
foreach ($taskProduct in @('PacerWindowsBridge','PacerInstallerHooks')) {
    swift build --build-system native @taskSwiftFlags @taskSwiftTargetFlags --package-path $SourcePath --scratch-path $ScratchPath --configuration $Configuration --product $taskProduct
    if ($LASTEXITCODE -ne 0) { throw ('Windows adapter build failed: ' + $taskProduct) }
}
