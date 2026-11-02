#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef ArtifactDir
  #error ArtifactDir is required
#endif
#ifndef PacerVersion
  #error PacerVersion is required
#endif
#ifndef PacerFileVersion
  #error PacerFileVersion is required
#endif
#ifndef PacerScope
  #define PacerScope "default"
#endif
#ifndef PacerAppId
  #define PacerAppId "CodexPacer.Windows"
#endif
#ifndef PacerAppName
  #define PacerAppName "Codex Pacer"
#endif
#ifndef ArtifactName
  #define ArtifactName "CodexPacer-setup"
#endif

[Setup]
AppId={#PacerAppId}
AppName={#PacerAppName}
AppVersion={#PacerVersion}
VersionInfoVersion={#PacerFileVersion}
AppPublisher=Codex Pacer contributors
AppPublisherURL=https://github.com/RyanZhangNTU/codex-pacer
DefaultDirName={localappdata}\Programs\{#PacerAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#ArtifactDir}
OutputBaseFilename={#ArtifactName}
SetupIconFile={#SourceDir}\Assets\Pacer.ico
UninstallDisplayIcon={app}\Assets\Pacer.ico
Compression=lzma2/fast
SolidCompression=yes
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
SignedUninstaller=no
WizardStyle=modern
DisableWelcomePage=no
LicenseFile={#SourceDir}\LICENSE.txt

[Files]
; First in the solid stream: repair uses a fresh, independent .NET host.
Source: "{#SourceDir}\Maintenance\PacerMaintenance.exe"; DestDir: "{app}\Maintenance"; Flags: ignoreversion
Source: "{#SourceDir}\build-info.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "Maintenance\PacerMaintenance.exe,build-info.json"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
var
  Bootstrap: String;

function Maintenance(const Host, Operation, Extra: String): Boolean;
var
  ExitCode: Integer;
  Arguments: String;
begin
  Arguments := Operation + ' {#PacerScope} ' + AddQuotes(ExpandConstant('{app}'));
  if Extra <> '' then Arguments := Arguments + ' ' + AddQuotes(Extra);
  Result := Exec(Host, Arguments, '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  if Result then Result := ExitCode = 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  ExtractTemporaryFile('PacerMaintenance.exe');
  ExtractTemporaryFile('build-info.json');
  Bootstrap := ExpandConstant('{tmp}\PacerMaintenance.exe');
  if not Maintenance(Bootstrap, 'prepare', ExpandConstant('{tmp}\build-info.json')) then
    Result := 'This installation could not be prepared. Close this copy of Codex Pacer, check file access, and try again.'
  else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    if not Maintenance(Bootstrap, 'register', '') then
      RaiseException('Pacer registration failed. Run this installer again to repair the installation.');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { After confirmation, before file removal. Exceptions are fatal at this step. }
  if CurUninstallStep = usUninstall then begin
    if not Maintenance(ExpandConstant('{app}\Maintenance\PacerMaintenance.exe'), 'uninstall', '') then
      RaiseException('Pacer could not safely remove its registrations and Claude hooks. Repair this installation and retry uninstalling.');
  end;
end;
