param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [ValidateSet('x64','arm64')][string]$Architecture = $(if ($env:PACER_ARCHITECTURE) { $env:PACER_ARCHITECTURE } else { 'x64' }))
$env:PACER_ARCHITECTURE = $Architecture
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
$taskVersion = Get-PacerVersion
$taskDestination = Join-Path $taskRoot ('output/windows/maintenance' + $(if ($Architecture -eq 'arm64') { '-arm64' } else { '' }))
dotnet publish (Join-Path $taskRoot 'windows/Maintenance/Pacer.Maintenance.csproj') --configuration $Configuration --runtime $taskArchitecture.RuntimeIdentifier --self-contained true --output $taskDestination -warnaserror -p:RestoreLockedMode=true "-p:PacerArchitecture=$Architecture" "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
if ($LASTEXITCODE -ne 0) { throw 'The self-contained maintenance build failed.' }
$taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows' + $taskArchitecture.DesktopSuffix + '/Maintenance')
New-Item -ItemType Directory -Path $taskDesktop -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskDestination 'PacerMaintenance.exe') -Destination $taskDesktop -Force
