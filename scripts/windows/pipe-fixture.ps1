function Get-DesktopPipeFixture {
    $taskPipeSource = Join-Path $taskRoot 'windows/Tests/Fixtures/DesktopPipe'
    $taskPipeOutput = Join-Path $taskRoot 'output/windows/desktop-pipe-fixture'
    $taskPipeExe = Join-Path $taskPipeOutput 'Pacer.DesktopPipeFixture.exe'
    $taskPipeReceipt = Join-Path $taskPipeOutput 'source.sha256'
    $taskPipeHash = (Get-FileHash -LiteralPath (Join-Path $taskPipeSource 'DesktopPipe.csproj')).Hash + (Get-FileHash -LiteralPath (Join-Path $taskPipeSource 'Program.cs')).Hash
    $taskPipeMutex = [Threading.Mutex]::new($false, 'Local\CodexPacer.DesktopPipeFixture')
    $taskPipeLocked = $false
    try {
        try { $taskPipeLocked = $taskPipeMutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $taskPipeLocked = $true }
        if (!$taskPipeLocked) { throw 'Another pipe fixture build is still running.' }
        if (!(Test-Path -LiteralPath $taskPipeExe) -or !(Test-Path -LiteralPath $taskPipeReceipt) -or (Get-Content -LiteralPath $taskPipeReceipt -Raw).Trim() -ne $taskPipeHash) {
            dotnet build (Join-Path $taskPipeSource 'DesktopPipe.csproj') --configuration Release --output $taskPipeOutput | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'The isolated pipe fixture could not build.' }
            [IO.File]::WriteAllText($taskPipeReceipt, $taskPipeHash)
        }
        return $taskPipeExe
    } finally { if ($taskPipeLocked) { $taskPipeMutex.ReleaseMutex() }; $taskPipeMutex.Dispose() }
}
