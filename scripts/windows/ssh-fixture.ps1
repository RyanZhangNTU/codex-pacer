function Get-SSHFixture {
    $taskSSHSource = Join-Path $taskRoot 'windows/Tests/Fixtures/SSH'
    $taskSSHOutput = Join-Path $taskRoot 'output/windows/ssh-fixture'
    $taskSSHExe = Join-Path $taskSSHOutput 'Pacer.SSHFixture.exe'
    $taskSSHReceipt = Join-Path $taskSSHOutput 'source.sha256'
    $taskSSHHash = (Get-FileHash -LiteralPath (Join-Path $taskSSHSource 'SSH.csproj')).Hash + (Get-FileHash -LiteralPath (Join-Path $taskSSHSource 'Program.cs')).Hash
    if (!(Test-Path -LiteralPath $taskSSHExe) -or !(Test-Path -LiteralPath $taskSSHReceipt) -or (Get-Content -LiteralPath $taskSSHReceipt -Raw).Trim() -ne $taskSSHHash) {
        dotnet build (Join-Path $taskSSHSource 'SSH.csproj') --configuration Release --output $taskSSHOutput | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'The synthetic SSH executable could not build.' }
        [IO.File]::WriteAllText($taskSSHReceipt, $taskSSHHash)
    }
    return $taskSSHExe
}
