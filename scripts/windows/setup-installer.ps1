. (Join-Path $PSScriptRoot 'environment.ps1')

function Get-PacerInstallerCompiler {
    $taskInnoLock = Get-Content -LiteralPath (Join-Path $taskRoot 'windows/installer-toolchain-lock.json') -Raw | ConvertFrom-Json
    $taskInnoDirectory = if ($env:PACER_INNO_ROOT) { [IO.Path]::GetFullPath($env:PACER_INNO_ROOT) } else {
        Join-Path $taskRoot ('output/toolchains/inno-' + $taskInnoLock.version)
    }
    $taskInnoCompiler = Join-Path $taskInnoDirectory 'ISCC.exe'
    $taskInnoReceiptPath = Join-Path $taskInnoDirectory 'pacer-toolchain.json'
    if (!(Test-Path -LiteralPath $taskInnoCompiler) -or !(Test-Path -LiteralPath $taskInnoReceiptPath)) {
        $taskDownloadRoot = Join-Path $taskRoot 'output/toolchains/downloads'
        New-Item -ItemType Directory -Path $taskDownloadRoot -Force | Out-Null
        $taskInnoArchive = Join-Path $taskDownloadRoot ('inno-' + $taskInnoLock.version + '.exe')
        if (!(Test-Path -LiteralPath $taskInnoArchive)) { Invoke-WebRequest -Uri $taskInnoLock.url -OutFile $taskInnoArchive }
        if ((Get-FileHash -LiteralPath $taskInnoArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskInnoLock.sha256) {
            throw 'The installer compiler hash differs from the pinned official asset.'
        }
        $taskInnoSignature = Get-AuthenticodeSignature -LiteralPath $taskInnoArchive
        if ($taskInnoSignature.Status -ne 'Valid' -or $taskInnoSignature.SignerCertificate.Subject -notmatch 'Pyrsys') {
            throw 'The installer compiler publisher signature is invalid.'
        }
        $taskInnoStart = [Diagnostics.ProcessStartInfo]::new($taskInnoArchive)
        $taskInnoStart.UseShellExecute = $false
        $taskInnoStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        foreach ($taskFlag in @('/portable=1','/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS','/TASKS=')) {
            $taskInnoStart.ArgumentList.Add($taskFlag)
        }
        $taskInnoStart.ArgumentList.Add('/DIR=' + $taskInnoDirectory)
        $taskInnoProcess = [Diagnostics.Process]::Start($taskInnoStart)
        try {
            if (!$taskInnoProcess.WaitForExit(60000)) { throw 'The portable compiler setup exceeded one minute.' }
            if ($taskInnoProcess.ExitCode -ne 0) { throw 'The portable compiler setup failed.' }
        } finally { $taskInnoProcess.Dispose() }
        $taskInnoFiles = @{}
        foreach ($taskPart in @('ISCC.exe','ISCmplr.dll','ISPP.dll')) {
            $taskInnoFiles[$taskPart] = (Get-FileHash -LiteralPath (Join-Path $taskInnoDirectory $taskPart) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText($taskInnoReceiptPath, (@{version=$taskInnoLock.version;archiveSha256=$taskInnoLock.sha256;files=$taskInnoFiles}|ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    $taskInnoReceipt = Get-Content -LiteralPath $taskInnoReceiptPath -Raw | ConvertFrom-Json
    if ($taskInnoReceipt.version -ne $taskInnoLock.version -or $taskInnoReceipt.archiveSha256 -ne $taskInnoLock.sha256) {
        throw 'The installer compiler version differs from the lock file.'
    }
    foreach ($taskPart in @('ISCC.exe','ISCmplr.dll','ISPP.dll')) {
        if ((Get-FileHash -LiteralPath (Join-Path $taskInnoDirectory $taskPart) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskInnoReceipt.files.$taskPart) {
            throw 'The pinned installer compiler files changed.'
        }
    }
    return $taskInnoCompiler
}
