function Set-PacerSelfContainedTestEnvironment([Diagnostics.ProcessStartInfo]$Start) {
    $Start.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
    foreach ($variable in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_ROOT_ARM64','DOTNET_HOST_PATH','DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','PACER_SWIFT_ROOT')) {
        $Start.Environment.Remove($variable) | Out-Null
    }
    $Start.Environment['DOTNET_MULTILEVEL_LOOKUP'] = '0'
}
