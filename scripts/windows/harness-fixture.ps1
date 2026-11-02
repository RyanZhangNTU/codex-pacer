function Get-HarnessMetadataFixture {
    $taskFixtureRoot = Join-Path $taskRoot 'windows/Tests/Fixtures/HarnessMetadata'
    $taskFixtureOutput = Join-Path $taskRoot 'output/windows/harness-metadata-fixture'
    $taskFixtureExe = Join-Path $taskFixtureOutput 'DeepSeek Harness.exe'
    $taskFixtureReceipt = Join-Path $taskFixtureOutput 'source.sha256'
    $taskFixtureHash = ((Get-FileHash -LiteralPath (Join-Path $taskFixtureRoot 'HarnessMetadata.csproj')).Hash + (Get-FileHash -LiteralPath (Join-Path $taskFixtureRoot 'Program.cs')).Hash)
    $taskFixtureMutex = [Threading.Mutex]::new($false, 'Local\CodexPacer.HarnessMetadataFixture')
    $taskFixtureLocked = $false
    try {
        $taskFixtureLocked = $taskFixtureMutex.WaitOne(30000)
        if (!$taskFixtureLocked) { throw 'Another metadata fixture build is still running.' }
        if (!(Test-Path -LiteralPath $taskFixtureExe) -or !(Test-Path -LiteralPath $taskFixtureReceipt) -or (Get-Content -LiteralPath $taskFixtureReceipt -Raw).Trim() -ne $taskFixtureHash) {
            dotnet build (Join-Path $taskFixtureRoot 'HarnessMetadata.csproj') --configuration Release --output $taskFixtureOutput | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'The synthetic desktop metadata fixture could not build.' }
            [IO.File]::WriteAllText($taskFixtureReceipt, $taskFixtureHash)
        }
        return $taskFixtureExe
    }
    finally { if ($taskFixtureLocked) { $taskFixtureMutex.ReleaseMutex() }; $taskFixtureMutex.Dispose() }
}
