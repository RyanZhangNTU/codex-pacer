param([string]$Filter = '')
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'harness-fixture.ps1')
. (Join-Path $PSScriptRoot 'pipe-fixture.ps1')
$taskPreviousHarnessFixture = $env:PACER_HARNESS_DESKTOP_FIXTURE
$taskPreviousPipeFixture = $env:PACER_DESKTOP_PIPE_FIXTURE
$env:PACER_HARNESS_DESKTOP_FIXTURE = Get-HarnessMetadataFixture
Push-Location $taskRoot
$taskPreviousCatalogReference = $env:PACER_UI_CATALOG_REFERENCE
$taskPreviousTestPython = $env:PACER_TEST_PYTHON
try {
    $env:PACER_DESKTOP_PIPE_FIXTURE = Get-DesktopPipeFixture
    python -S scripts/windows/build-localization.py --check
    if ($LASTEXITCODE -ne 0) { throw 'The Windows UI catalogs must match their shared sources.' }
    $env:PACER_UI_CATALOG_REFERENCE = Join-Path $taskRoot 'windows/Localization/Catalogs'
    $env:PACER_TEST_PYTHON = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $taskStage = & python -S scripts/windows/stage-engine.py
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Windows source snapshot.' }
    $taskTests = @()
    if ($Filter) { $taskTests = @('--filter', $Filter) }
    $taskEntry = Join-Path $taskRoot 'windows/Tests/XCTestMain.swift'
    swift test --build-system native --enable-xctest --disable-swift-testing --experimental-test-entry-point-path $taskEntry @taskSwiftFlags --package-path $taskStage --scratch-path $taskScratchPath @taskTests
    if ($LASTEXITCODE -ne 0) { throw 'Windows engine tests failed.' }
} finally { $env:PACER_UI_CATALOG_REFERENCE = $taskPreviousCatalogReference; $env:PACER_TEST_PYTHON = $taskPreviousTestPython; $env:PACER_HARNESS_DESKTOP_FIXTURE = $taskPreviousHarnessFixture; $env:PACER_DESKTOP_PIPE_FIXTURE = $taskPreviousPipeFixture; Pop-Location }
