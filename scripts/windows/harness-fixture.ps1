function Get-HarnessMetadataFixture([switch]$Electron) {
    # -Electron builds the earlier desktop (0.2.1), which kept Electron's company name.
    $taskFixtureCompany = if ($Electron) { 'GitHub, Inc.' } else { '' }
    $taskFixtureRoot = Join-Path $taskRoot 'windows/Tests/Fixtures/HarnessMetadata'
    $taskFixtureOutput = Join-Path $taskRoot ('output/windows/harness-metadata-fixture' + $(if ($Electron) { '-electron' } else { '' }))
    $taskFixtureExe = Join-Path $taskFixtureOutput 'DeepSeek Harness.exe'
    $taskFixtureReceipt = Join-Path $taskFixtureOutput 'source.sha256'
    $taskFixtureHash = ((Get-FileHash -LiteralPath (Join-Path $taskFixtureRoot 'HarnessMetadata.csproj')).Hash + (Get-FileHash -LiteralPath (Join-Path $taskFixtureRoot 'Program.cs')).Hash + $taskFixtureCompany)
    $taskFixtureMutex = [Threading.Mutex]::new($false, 'Local\CodexPacer.HarnessMetadataFixture')
    $taskFixtureLocked = $false
    $taskPreviousCompany = $env:HarnessFixtureCompany
    try {
        $taskFixtureLocked = $taskFixtureMutex.WaitOne(30000)
        if (!$taskFixtureLocked) { throw 'Another metadata fixture build is still running.' }
        if (!(Test-Path -LiteralPath $taskFixtureExe) -or !(Test-Path -LiteralPath $taskFixtureReceipt) -or (Get-Content -LiteralPath $taskFixtureReceipt -Raw).Trim() -ne $taskFixtureHash) {
            # An environment variable keeps the comma in a company name away from MSBuild's -p parsing.
            $env:HarnessFixtureCompany = $taskFixtureCompany
            dotnet build (Join-Path $taskFixtureRoot 'HarnessMetadata.csproj') --configuration Release --output $taskFixtureOutput | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'The synthetic desktop metadata fixture could not build.' }
            [IO.File]::WriteAllText($taskFixtureReceipt, $taskFixtureHash)
        }
        return $taskFixtureExe
    }
    finally { $env:HarnessFixtureCompany = $taskPreviousCompany; if ($taskFixtureLocked) { $taskFixtureMutex.ReleaseMutex() }; $taskFixtureMutex.Dispose() }
}
