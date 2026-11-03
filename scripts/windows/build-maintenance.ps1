param([ValidateSet('Debug','Release')][string]$Configuration = 'Release')
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
$taskVersion = Get-PacerVersion
$taskDestination = Join-Path $taskRoot 'output/windows/maintenance'
dotnet publish (Join-Path $taskRoot 'windows/Maintenance/Pacer.Maintenance.csproj') --configuration $Configuration --runtime win-x64 --self-contained true --output $taskDestination -warnaserror -p:RestoreLockedMode=true "-p:Version=$($taskVersion.version)" "-p:FileVersion=$($taskVersion.version).$($taskVersion.build)"
if ($LASTEXITCODE -ne 0) { throw 'The self-contained maintenance build failed.' }
$taskDesktop = Join-Path $taskRoot ('windows/Desktop/bin/' + $Configuration + '/net10.0-windows/Maintenance')
New-Item -ItemType Directory -Path $taskDesktop -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskDestination 'PacerMaintenance.exe') -Destination $taskDesktop -Force
