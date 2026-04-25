param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-pacer-release-test-" + [System.Guid]::NewGuid().ToString("N"))
$stubBin = Join-Path $testRoot "bin"
$logDir = Join-Path $testRoot "logs"
$targetDir = Join-Path $testRoot "target"
$releaseVersion = (Get-Content -LiteralPath (Join-Path $repoRoot "package.json") -Raw | ConvertFrom-Json).version
$releaseScript = Join-Path $repoRoot "scripts\release\build-windows-release.ps1"
$previousEnv = @{}

function Save-EnvVar {
  param([Parameter(Mandatory = $true)][string]$Name)

  $previousEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-EnvVars {
  foreach ($name in $previousEnv.Keys) {
    [Environment]::SetEnvironmentVariable($name, $previousEnv[$name], "Process")
  }
}

function Write-Stub {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Body
  )

  Set-Content -LiteralPath (Join-Path $stubBin $Name) -Value $Body -Encoding UTF8
}

function Clear-LogsAndTarget {
  Remove-Item -LiteralPath $env:TEST_NPM_LOG, $env:TEST_CARGO_LOG -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $env:CARGO_TARGET_DIR -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $env:CARGO_TARGET_DIR | Out-Null
}

function Quote-ProcessArgument {
  param([Parameter(Mandatory = $true)][string]$Value)

  '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-ReleaseScript {
  param([string[]]$ExtraArgs = @())

  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Quote-ProcessArgument $releaseScript),
    "-Version",
    (Quote-ProcessArgument $releaseVersion)
  ) + $ExtraArgs

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = "powershell"
  $startInfo.Arguments = ($arguments -join " ")
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  [pscustomobject]@{
    ExitCode = $process.ExitCode
    Output = "$stdout$stderr"
  }
}

function Assert-BuildCommandsRan {
  $npmLog = Get-Content -LiteralPath $env:TEST_NPM_LOG -Raw
  $cargoLog = Get-Content -LiteralPath $env:TEST_CARGO_LOG -Raw

  if ($npmLog -notmatch "(?m)^ci\s*$") {
    throw "expected npm ci to run"
  }
  if ($npmLog -notmatch "(?m)^run lint\s*$") {
    throw "expected npm run lint to run"
  }
  if ($npmLog -notmatch "(?m)^run build\s*$") {
    throw "expected npm run build to run"
  }
  if ($cargoLog -notmatch "test --manifest-path src-tauri[/\\]Cargo\.toml --locked") {
    throw "expected cargo test to run with --locked"
  }
  if ($npmLog -notmatch "run tauri build -- --ci --bundles nsis -- --locked") {
    throw "expected Tauri build to request the NSIS bundle with locked Cargo dependencies"
  }
}

try {
  Save-EnvVar "Path"
  Save-EnvVar "TEST_NPM_LOG"
  Save-EnvVar "TEST_CARGO_LOG"
  Save-EnvVar "TEST_RELEASE_VERSION"
  Save-EnvVar "TEST_GIT_DIRTY"
  Save-EnvVar "CARGO_TARGET_DIR"

  New-Item -ItemType Directory -Path $stubBin, $logDir, $targetDir | Out-Null

  Write-Stub "git.cmd" @"
@echo off
if "%1"=="rev-parse" (
  if "%2"=="--is-inside-work-tree" (
    echo true
    exit /b 0
  )
)
if "%1"=="update-index" exit /b 0
if "%1"=="status" (
  if "%TEST_GIT_DIRTY%"=="1" (
    echo  M dirty-file.txt
  )
  exit /b 0
)
echo unexpected git invocation: %* 1>&2
exit /b 1
"@

  Write-Stub "cargo.cmd" @"
@echo off
echo %*>> "%TEST_CARGO_LOG%"
if "%1"=="test" exit /b 0
echo unexpected cargo invocation: %* 1>&2
exit /b 1
"@

  Write-Stub "npm.cmd" @"
@echo off
echo %*>> "%TEST_NPM_LOG%"
if "%1"=="ci" exit /b 0
if "%1"=="run" if "%2"=="lint" exit /b 0
if "%1"=="run" if "%2"=="build" exit /b 0
if "%1"=="run" if "%2"=="tauri" if "%3"=="build" (
  mkdir "%CARGO_TARGET_DIR%\release\bundle\nsis" >nul 2>nul
  mkdir "%CARGO_TARGET_DIR%\release\other" >nul 2>nul
  echo fake installer> "%CARGO_TARGET_DIR%\release\bundle\nsis\Codex Pacer_%TEST_RELEASE_VERSION%_x64-setup.exe"
  echo wrong installer> "%CARGO_TARGET_DIR%\release\other\Codex Pacer_%TEST_RELEASE_VERSION%_x64-setup.exe"
  exit /b 0
)
echo unexpected npm invocation: %* 1>&2
exit /b 1
"@

  $env:Path = "$stubBin;$env:Path"
  $env:TEST_NPM_LOG = Join-Path $logDir "npm.log"
  $env:TEST_CARGO_LOG = Join-Path $logDir "cargo.log"
  $env:TEST_RELEASE_VERSION = $releaseVersion
  $env:CARGO_TARGET_DIR = $targetDir

  Clear-LogsAndTarget
  $env:TEST_GIT_DIRTY = "1"
  $dirtyResult = Invoke-ReleaseScript
  if ($dirtyResult.ExitCode -eq 0) {
    throw "expected default release build to fail when git status reports a dirty tree"
  }
  if ($dirtyResult.Output -notmatch "Working tree is not clean") {
    throw "expected dirty-tree failure to mention the clean working tree requirement"
  }
  if (Test-Path -LiteralPath $env:TEST_NPM_LOG -PathType Leaf) {
    throw "expected dirty-tree failure to stop before npm commands run"
  }

  Clear-LogsAndTarget
  $env:TEST_GIT_DIRTY = "0"
  $cleanResult = Invoke-ReleaseScript
  if ($cleanResult.ExitCode -ne 0) {
    throw "expected default release build to reach build commands when git status reports clean. Output: $($cleanResult.Output)"
  }

  $installer = Join-Path $targetDir "release\bundle\nsis\Codex Pacer_${releaseVersion}_x64-setup.exe"
  $wrongInstaller = Join-Path $targetDir "release\other\Codex Pacer_${releaseVersion}_x64-setup.exe"
  $checksum = "$installer.sha256"
  $wrongChecksum = "$wrongInstaller.sha256"
  $escapedInstallerName = [regex]::Escape("Codex Pacer_${releaseVersion}_x64-setup.exe")

  Assert-BuildCommandsRan
  if (!(Test-Path -LiteralPath $checksum -PathType Leaf)) {
    throw "expected checksum to be written beside the mocked NSIS installer"
  }
  if (Test-Path -LiteralPath $wrongChecksum -PathType Leaf) {
    throw "expected installer discovery to ignore matching setup exe files outside the NSIS bundle directory"
  }
  if ((Get-Content -LiteralPath $checksum -Raw) -notmatch $escapedInstallerName) {
    throw "expected checksum file to reference the installer filename"
  }

  Write-Host "build-windows-release regression test passed"
}
finally {
  Restore-EnvVars
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
