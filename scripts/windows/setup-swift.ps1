param([ValidateSet('x64','arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$env:PACER_ARCHITECTURE = $Architecture
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$taskLock = Get-Content -LiteralPath (Join-Path $taskRoot 'windows/toolchain-lock.json') -Raw | ConvertFrom-Json
if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant() -ne $Architecture) { throw 'Install Swift on a matching host. The ARM64 CI job uses a native ARM64 runner.' }
$taskVersion = $taskLock.swiftVersion
$taskRootSwift = Join-Path $taskRoot 'output/toolchains/swift'
$taskInstaller = Join-Path $taskRoot ('output/toolchains/swift-' + $taskVersion + '-' + $Architecture + '.exe')
$taskTargetSuffix = if ($Architecture -eq 'arm64') { '-arm64' } else { '' }
$taskExpectedHash = if ($Architecture -eq 'arm64') { $taskLock.swiftArm64InstallerSHA256 } else { $taskLock.swiftInstallerSHA256 }
$taskCompiler = Join-Path $taskRootSwift ('Toolchains/' + $taskVersion + '+Asserts/usr/bin')
New-Item -ItemType Directory -Path (Split-Path $taskInstaller) -Force | Out-Null
if (!(Test-Path -LiteralPath (Join-Path $taskCompiler 'swift.exe'))) {
    $taskURL = 'https://download.swift.org/swift-' + $taskVersion + '-release/windows10' + $taskTargetSuffix + '/swift-' + $taskVersion + '-RELEASE/swift-' + $taskVersion + '-RELEASE-windows10' + $taskTargetSuffix + '.exe'
    if (!(Test-Path -LiteralPath $taskInstaller)) { Invoke-WebRequest -Uri $taskURL -OutFile $taskInstaller }
    if ((Get-FileHash -LiteralPath $taskInstaller -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskExpectedHash) {
        throw 'The Swift installer does not match the pinned checksum.'
    }
    $taskSignature = Get-AuthenticodeSignature -LiteralPath $taskInstaller
    if ($taskSignature.Status -ne 'Valid' -or $taskSignature.SignerCertificate.Subject -notmatch 'Apple Inc') {
        throw 'The Swift installer signature could not be verified.'
    }
    $taskArguments = @('/quiet', '/norestart', ('InstallRoot="' + $taskRootSwift + '"'),
        'OptionsInstallIDE=0', 'OptionsInstallPy=0', 'OptionsInstallDBG=0', 'OptionsInstallAndroidPlatform=0',
        'OptionsInstallAndroidSDKARM64=0', 'OptionsInstallAndroidSDKAMD64=0', 'OptionsInstallWindowsSDKX86=0',
        ('OptionsInstallWindowsSDKARM64=' + $(if ($Architecture -eq 'arm64') { '1' } else { '0' })),
        ('OptionsInstallWindowsSDKAMD64=' + $(if ($Architecture -eq 'x64') { '1' } else { '0' })), 'OptionsInstallWindowsRedistX86=0')
    $taskInstall = Start-Process -FilePath $taskInstaller -ArgumentList $taskArguments -WindowStyle Hidden -Wait -PassThru
    if ($taskInstall.ExitCode -notin @(0, 3010)) { throw ('Swift installer failed with exit code ' + $taskInstall.ExitCode) }
}

# The 6.4.2 CLI loads these side-by-side assemblies from its own directory.
# Keep the repair inside this task's toolchain; never patch a system SDK.
$taskRuntimeDirectory = Join-Path $taskRootSwift ('Runtimes/' + $taskVersion + '/usr/bin')
foreach ($taskAssembly in @('FoundationXML', 'swiftRegexBuilder')) {
    $taskAssemblyDirectory = Join-Path $taskCompiler $taskAssembly
    $taskLibrary = Join-Path $taskRuntimeDirectory ($taskAssembly + '.dll')
    if (!(Test-Path -LiteralPath $taskLibrary)) { throw ('Swift runtime dependency is missing: ' + $taskAssembly) }
    New-Item -ItemType Directory -Path $taskAssemblyDirectory -Force | Out-Null
    Copy-Item -LiteralPath $taskLibrary -Destination $taskAssemblyDirectory -Force
    if ($taskAssembly -eq 'swiftRegexBuilder') {
        $taskProcessor = if ($Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
        $taskManifest = '<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><assemblyIdentity type="win32" name="swiftRegexBuilder" version="6.4.2.0" processorArchitecture="' + $taskProcessor + '"/><file name="swiftRegexBuilder.dll"/></assembly>'
        [IO.File]::WriteAllText((Join-Path $taskAssemblyDirectory 'swiftRegexBuilder.manifest'), $taskManifest, [Text.UTF8Encoding]::new($false))
    }
}
. (Join-Path $PSScriptRoot 'environment.ps1')
swift --version
if ($LASTEXITCODE -ne 0) { throw 'The Swift toolchain could not start.' }
swift-build --version
if ($LASTEXITCODE -ne 0) { throw 'The Swift package manager could not start.' }
