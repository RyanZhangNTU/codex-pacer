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
UninstallLogging=yes
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
  MaintenanceExitCode: Integer;

function Maintenance(const Host, Operation, Extra: String): Boolean;
var
  ExitCode: Integer;
  Arguments: String;
begin
  Arguments := Operation + ' {#PacerScope} ' + AddQuotes(ExpandConstant('{app}'));
  if Extra <> '' then Arguments := Arguments + ' ' + AddQuotes(Extra);
  Result := Exec(Host, Arguments, '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  MaintenanceExitCode := ExitCode;
  if not Result then MaintenanceExitCode := 24;
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

function CleanupInstructions(const Code: Integer): String;
begin
  Result := '';
  if Code <> 22 then
    Result := 'Claude configuration could not be cleaned. The affected files are settings.json and pacer\installation.json in the Claude configuration folder: %CLAUDE_CONFIG_DIR%, otherwise %USERPROFILE%\.claude, and any Claude Home selected in Pacer settings.'#13#10#13#10 +
      'Manual cleanup: in settings.json, remove only Pacer command entries under hooks that launch pacer/hook.py. If statusLine.command launches that Pacer wrapper, restore previousStatusLine from pacer\installation.json (or remove statusLine when the saved value is null). Remove an env value only when it still equals the value recorded in addedEnvironment. Preserve all user and other application entries. Then remove pacer\installation.json.'#13#10#13#10;
  if (Code <> 21) then
    Result := Result + 'Some Windows registrations could not be cleaned. Retained items may include this installation''s current-user Run/StartupApproved entry, Start menu shortcut, Software\CodexPacer\Installations marker, or notification activation registration. Remove only entries that still point to this installation; leave other entries unchanged.'#13#10#13#10;
  Result := Result + 'Continuing removes the application but preserves anything that could not be cleaned. Retained Pacer hooks may call a deleted program and cause Claude Code errors until you remove those Pacer entries manually. Preferences and read state are retained.';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Choice, Attempts: Integer;
  TestChoice, Instructions: String;
begin
  { After confirmation, before file removal. Exceptions are fatal at this step. }
  if CurUninstallStep = usUninstall then begin
    Attempts := 0;
    while not Maintenance(ExpandConstant('{app}\Maintenance\PacerMaintenance.exe'), 'uninstall', '') do begin
      Instructions := CleanupInstructions(MaintenanceExitCode);
      Log('Pacer cleanup failure code ' + IntToStr(MaintenanceExitCode) + '. ' + Instructions);
      TestChoice := '';
      { QA packages alone can simulate the interactive decision in CI. }
      if '{#PacerScope}' <> 'default' then
        TestChoice := ExpandConstant('{param:PACERQAUNINSTALL|}');
      if TestChoice = 'continue' then Choice := IDIGNORE
      else if (TestChoice = 'retry-once') and (Attempts = 0) then Choice := IDRETRY
      else if (TestChoice = 'cancel') or (TestChoice = 'retry-once') then Choice := IDABORT
      else if UninstallSilent then
        RaiseException('Pacer cleanup failed. Silent uninstall was stopped before application file removal. See the uninstall log for manual cleanup instructions.')
      else
        Choice := TaskDialogMsgBox('Pacer cleanup could not finish', Instructions,
          mbError, MB_ABORTRETRYIGNORE, ['Retry', 'Continue uninstall', 'Cancel'], 0);
      if Choice = IDRETRY then begin
        Attempts := Attempts + 1;
        Log('Pacer cleanup retry requested.');
      end else if Choice = IDIGNORE then begin
        { Same maintenance entry and ownership checks, now best-effort. }
        if not Maintenance(ExpandConstant('{app}\Maintenance\PacerMaintenance.exe'), 'uninstall-continue', '') then
          Log('Pacer continued cleanup code ' + IntToStr(MaintenanceExitCode) + '. ' + CleanupInstructions(MaintenanceExitCode));
        Log('Pacer application removal explicitly continued with retained cleanup items.');
        Break;
      end else
        RaiseException('Uninstall cancelled. Application files have not been removed.');
    end;
  end;
end;
