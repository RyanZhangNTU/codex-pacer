[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Version,

  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..\..")

function Require-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Require-CleanWorktree {
  if ($AllowDirty) {
    Write-Host "AllowDirty is set; skipping clean working tree check."
    return
  }

  $insideWorktree = & git rev-parse --is-inside-work-tree
  if ($LASTEXITCODE -ne 0 -or $insideWorktree -ne "true") {
    throw "$RepoRoot is not inside a git work tree."
  }

  & git update-index -q --refresh
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to refresh git index."
  }

  $status = & git status --porcelain
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect git status."
  }

  if ($status) {
    [Console]::Error.WriteLine("ERROR: Working tree is not clean. Commit, stash, or remove local changes before building a release, or pass -AllowDirty explicitly.")
    & git status --short
    exit 1
  }
}

function Get-BuildTargetRoot {
  if ($env:CARGO_TARGET_DIR) {
    return [System.IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)
  }

  return Join-Path $RepoRoot "src-tauri\target"
}

function Get-LatestRecentNsisInstaller {
  param(
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][datetime]$BuildStart,
    [Parameter(Mandatory = $true)][string]$ExpectedProductName,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion
  )

  $nsisBundleDir = Join-Path $TargetRoot "release\bundle\nsis"
  if (-not (Test-Path -LiteralPath $nsisBundleDir -PathType Container)) {
    return $null
  }

  $expectedInstallerPattern = "{0}_{1}_*setup.exe" -f ([WildcardPattern]::Escape($ExpectedProductName)), ([WildcardPattern]::Escape($ExpectedVersion))

  Get-ChildItem -LiteralPath $nsisBundleDir -File -Filter "*.exe" |
    Where-Object {
      $_.LastWriteTime -ge $BuildStart -and
      $_.Name -like $expectedInstallerPattern
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Write-Sha256Checksum {
  param([Parameter(Mandatory = $true)][System.IO.FileInfo]$Installer)

  $hash = Get-FileHash -LiteralPath $Installer.FullName -Algorithm SHA256
  $checksumPath = "$($Installer.FullName).sha256"
  Set-Content -LiteralPath $checksumPath -Value ("{0}  {1}" -f $hash.Hash.ToLowerInvariant(), $Installer.Name) -Encoding ASCII
  return $checksumPath
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgumentList
  )

  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
  }
}

function Main {
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "Windows release builds must run on Windows PowerShell or PowerShell on Windows."
  }

  Require-Command "git"
  Require-Command "node"
  Require-Command "npm"
  Require-Command "cargo"

  Push-Location $RepoRoot
  try {
    Require-CleanWorktree

    $package = Read-JsonFile (Join-Path $RepoRoot "package.json")
    $tauriConfig = Read-JsonFile (Join-Path $RepoRoot "src-tauri\tauri.conf.json")

    if ($package.version -ne $Version) {
      throw "package.json version is $($package.version), expected $Version."
    }

    if ($tauriConfig.version -ne $Version) {
      throw "src-tauri/tauri.conf.json version is $($tauriConfig.version), expected $Version."
    }

    $productName = $tauriConfig.productName
    if (-not $productName) {
      throw "src-tauri/tauri.conf.json productName is required to locate the NSIS installer."
    }

    $targetRoot = Get-BuildTargetRoot
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    $env:CARGO_TARGET_DIR = $targetRoot

    Write-Host "Building Codex Pacer v$Version for Windows"
    Write-Host "Cargo target dir : $targetRoot"
    Write-Host "Signing          : not configured; this build is unsigned."
    Write-Host ""

    Write-Host "Installing dependencies from the committed package-lock.json..."
    Invoke-Checked "npm" "ci"

    Write-Host ""
    Write-Host "Running lint..."
    Invoke-Checked "npm" "run" "lint"

    Write-Host ""
    Write-Host "Building frontend..."
    Invoke-Checked "npm" "run" "build"

    Write-Host ""
    Write-Host "Running Rust tests..."
    Invoke-Checked "cargo" "test" "--manifest-path" "src-tauri/Cargo.toml" "--locked"

    Write-Host ""
    Write-Host "Running Tauri NSIS release build..."
    $buildStart = Get-Date
    Invoke-Checked "npm" "run" "tauri" "build" "--" "--ci" "--bundles" "nsis" "--" "--locked"

    $installer = Get-LatestRecentNsisInstaller -TargetRoot $targetRoot -BuildStart $buildStart -ExpectedProductName $productName -ExpectedVersion $Version
    if (-not $installer) {
      throw "Could not locate the generated NSIS setup exe for $productName version $Version under $(Join-Path $targetRoot 'release\bundle\nsis')."
    }

    Write-Host ""
    Write-Host "Writing installer checksum..."
    $checksumPath = Write-Sha256Checksum -Installer $installer

    Write-Host ""
    Write-Host "Build complete."
    Write-Host "Installer : $($installer.FullName)"
    Write-Host "Checksum  : $checksumPath"
    Write-Host "Note      : Windows code signing is not configured; installer is unsigned."
  }
  finally {
    Pop-Location
  }
}

Main
