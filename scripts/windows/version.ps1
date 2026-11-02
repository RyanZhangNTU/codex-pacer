function Get-PacerVersion {
    $taskManifest = Join-Path $PSScriptRoot '../../native/Info.plist'
    $taskVersion = (& python -S -c 'import json,plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); print(json.dumps({"version":p["CFBundleShortVersionString"],"build":p["CFBundleVersion"]}))' $taskManifest) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $taskVersion.version -notmatch '^\d+\.\d+\.\d+$' -or $taskVersion.build -notmatch '^\d+$') {
        throw 'The shared application version is invalid.'
    }
    return $taskVersion
}
