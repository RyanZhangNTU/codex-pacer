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
#ifndef PacerArchitecture
  #define PacerArchitecture "x64"
#endif
#ifndef PacerCompression
  #define PacerCompression "lzma2/ultra64"
#endif
; A patch installer (PacerPatch) carries only changed files in SourceDir; its
; icon and license still come from the complete payload.
#ifndef PacerAssetsDir
  #define PacerAssetsDir SourceDir
#endif
#ifdef PacerPatch
  #ifndef PacerPatchFile
    #error PacerPatchFile is required for a patch installer
  #endif
#endif

[Setup]
AppId={#PacerAppId}
AppName={#PacerAppName}
VersionInfoProductName={#PacerAppName}
VersionInfoDescription={#PacerAppName} Setup
AppVersion={#PacerVersion}
VersionInfoVersion={#PacerFileVersion}
AppPublisher=Codex Pacer contributors
AppPublisherURL=https://github.com/RyanZhangNTU/codex-pacer
DefaultDirName={localappdata}\Programs\{#PacerAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
#if PacerArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#elif PacerArchitecture == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
  #error PacerArchitecture must be x64 or arm64
#endif
MinVersion=10.0.19041
OutputDir={#ArtifactDir}
OutputBaseFilename={#ArtifactName}
SetupIconFile={#PacerAssetsDir}\Assets\Pacer.ico
UninstallDisplayIcon={app}\Assets\Pacer.ico
Compression={#PacerCompression}
SolidCompression=yes
; The 64-bit compressor keeps ultra64's dictionary out of 32-bit ISCC.
LZMAUseSeparateProcess=yes
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
SignedUninstaller=no
UninstallLogging=yes
WizardStyle=modern
DisableWelcomePage=no
LicenseFile={#PacerAssetsDir}\LICENSE.txt
; Chinese on a Chinese Windows UI, English otherwise; a selector only when
; neither matches.
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "..\ThirdParty\InnoSetup\ChineseSimplified.isl"

[CustomMessages]
english.PacerPrepareFailed=This installation could not be prepared. Close this copy of Codex Pacer, check file access, and try again.
chinesesimplified.PacerPrepareFailed=无法准备此安装。请关闭正在运行的 Codex Pacer，检查文件访问权限，然后重试。
english.PacerRegistrationFailed=Pacer registration failed. Run this installer again to repair the installation.
chinesesimplified.PacerRegistrationFailed=Pacer 注册失败。请再次运行此安装程序以修复安装。
english.PacerCleanupClaude=Claude configuration could not be cleaned. The affected files are settings.json and pacer\installation.json in the Claude configuration folder: %CLAUDE_CONFIG_DIR%, otherwise %USERPROFILE%\.claude, and any Claude Home selected in Pacer settings.
chinesesimplified.PacerCleanupClaude=无法清理 Claude 配置。涉及 Claude 配置文件夹中的 settings.json 和 pacer\installation.json：%CLAUDE_CONFIG_DIR%，未设置时为 %USERPROFILE%\.claude，以及 Pacer 设置中选择的 Claude Home。
english.PacerCleanupClaudeManual=Manual cleanup: in settings.json, remove only Pacer command entries under hooks that launch pacer/hook.py. If statusLine.command launches that Pacer wrapper, restore previousStatusLine from pacer\installation.json (or remove statusLine when the saved value is null). Remove an env value only when it still equals the value recorded in addedEnvironment. Preserve all user and other application entries. Then remove pacer\installation.json.
chinesesimplified.PacerCleanupClaudeManual=手动清理：在 settings.json 中，只删除 hooks 下启动 pacer/hook.py 的 Pacer 命令条目。如果 statusLine.command 启动的是 Pacer 的包装程序，请用 pacer\installation.json 中的 previousStatusLine 恢复（保存的值为 null 时删除 statusLine）。只有当 env 中的值仍等于 addedEnvironment 记录的值时才删除它。保留所有用户和其他应用的条目，最后删除 pacer\installation.json。
english.PacerCleanupRegistrations=Some Windows registrations could not be cleaned. Retained items may include this installation's current-user Run/StartupApproved entry, Start menu or desktop shortcut, Software\CodexPacer\Installations marker, or notification activation registration. Remove only entries that still point to this installation; leave other entries unchanged.
chinesesimplified.PacerCleanupRegistrations=部分 Windows 注册项无法清理。保留的项目可能包括此安装的当前用户 Run/StartupApproved 启动项、开始菜单或桌面快捷方式、Software\CodexPacer\Installations 标记或通知激活注册。只删除仍指向此安装的条目，其他条目保持不变。
english.PacerCleanupRuntime=The shared Python runtime is under %LOCALAPPDATA%\CodexPacer\ClaudeRuntime. Keep versions still referenced by any hook, and preserve unknown or modified files.
chinesesimplified.PacerCleanupRuntime=共享的 Python 运行时位于 %LOCALAPPDATA%\CodexPacer\ClaudeRuntime。请保留仍被任何 hook 引用的版本，以及未知或已修改的文件。
english.PacerCleanupContinue=Continuing removes the application but preserves anything that could not be cleaned. Retained Pacer hooks may call a deleted program and cause Claude Code errors until you remove those Pacer entries manually. Preferences and read state are retained.
chinesesimplified.PacerCleanupContinue=继续卸载会删除应用程序，但保留无法清理的内容。在你手动删除这些 Pacer 条目之前，保留的 Pacer hook 可能会调用已删除的程序，导致 Claude Code 报错。偏好设置和已读状态会保留。
english.PacerCleanupTitle=Pacer cleanup could not finish
chinesesimplified.PacerCleanupTitle=Pacer 清理未能完成
english.PacerRetry=Retry
chinesesimplified.PacerRetry=重试
english.PacerContinueUninstall=Continue uninstall
chinesesimplified.PacerContinueUninstall=继续卸载
english.PacerCancel=Cancel
chinesesimplified.PacerCancel=取消
english.PacerSilentUninstallStopped=Pacer cleanup failed. Silent uninstall was stopped before application file removal. See the uninstall log for manual cleanup instructions.
chinesesimplified.PacerSilentUninstallStopped=Pacer 清理失败。静默卸载已在删除应用文件前停止。手动清理说明见卸载日志。
english.PacerStartMenuShortcut=Add to the &Start menu
chinesesimplified.PacerStartMenuShortcut=添加到开始菜单(&S)
english.PacerPatchMismatch=This update package applies only to the Codex Pacer installation it was made for, and this one differs. Download the full installer from the GitHub release instead.
chinesesimplified.PacerPatchMismatch=此更新包只适用于它所对应的 Codex Pacer 安装，当前安装与之不符。请改为从 GitHub Release 下载完整安装包。
english.PacerPatchVerifyFailed=The updated files could not be verified. Run the full installer from the GitHub release to repair Codex Pacer.
chinesesimplified.PacerPatchVerifyFailed=更新后的文件未通过校验。请从 GitHub Release 下载完整安装包，运行它来修复 Codex Pacer。
english.PacerUninstallCancelled=Uninstall cancelled. Application files have not been removed.
chinesesimplified.PacerUninstallCancelled=卸载已取消，应用文件没有被删除。

[Dirs]
; Maintenance creates {app} before Setup does, so Setup would otherwise leave
; it behind, empty, after uninstalling.
Name: "{app}"; Flags: uninsalwaysuninstall

[Run]
; The finish page offers both shortcuts and launch, all checked. Maintenance
; owns the shortcuts, so uninstall removes them only while unchanged. A silent
; update skips them (registration refreshes the ones already owned) and
; relaunches through its own handoff; a silent new installation gets both.
Filename: "{app}\Maintenance\PacerMaintenance.exe"; Parameters: "shortcut {#PacerScope} ""{app}"" desktop"; Description: "{cm:CreateDesktopIcon}"; Flags: postinstall runhidden waituntilterminated; Check: OfferShortcuts
Filename: "{app}\Maintenance\PacerMaintenance.exe"; Parameters: "shortcut {#PacerScope} ""{app}"" start-menu"; Description: "{cm:PacerStartMenuShortcut}"; Flags: postinstall runhidden waituntilterminated; Check: OfferShortcuts
#if PacerScope == "default"
Filename: "{app}\CodexPacer.exe"; Description: "{cm:LaunchProgram,{#PacerAppName}}"; Flags: nowait postinstall skipifsilent
#else
Filename: "{app}\CodexPacer.exe"; Parameters: "--demo --reference-fixture --activation-qa {#PacerScope}"; Description: "{cm:LaunchProgram,{#PacerAppName}}"; Flags: nowait postinstall skipifsilent
#endif

[Files]
; First in the solid stream: repair uses a fresh, independent .NET host.
Source: "{#SourceDir}\Maintenance\PacerMaintenance.exe"; DestDir: "{app}\Maintenance"; Flags: ignoreversion
Source: "{#SourceDir}\build-info.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "Maintenance\PacerMaintenance.exe,build-info.json"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef PacerPatch
Source: "{#PacerPatchFile}"; Flags: dontcopy
#endif

[Code]
var
  Bootstrap: String;
  MaintenanceExitCode: Integer;
  Upgrading: Boolean;

function InitializeSetup: Boolean;
begin
  Upgrading := RegKeyExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#PacerAppId}_is1');
  Result := True;
end;

function OfferShortcuts: Boolean;
begin
  Result := not WizardSilent or not Upgrading;
end;

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
#ifdef PacerPatch
  { Before any file changes: the installation must be exactly this patch's
    base, and every file the patch does not carry must already be current. }
  ExtractTemporaryFile('pacer-patch.json');
  if not Maintenance(Bootstrap, 'prepare-patch', ExpandConstant('{tmp}\pacer-patch.json')) then
    Result := CustomMessage('PacerPatchMismatch')
#else
  if not Maintenance(Bootstrap, 'prepare', ExpandConstant('{tmp}\build-info.json')) then
    Result := CustomMessage('PacerPrepareFailed')
#endif
  else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    { Best effort: a file the old version listed that is still present is
      harmless, and a changed or unknown file is kept. }
    if not Maintenance(Bootstrap, 'remove-stale', ExpandConstant('{tmp}\pacer-stale.json')) then
      Log('Pacer stale file removal code ' + IntToStr(MaintenanceExitCode) + '.');
    if not Maintenance(Bootstrap, 'register', '') then
      RaiseException(CustomMessage('PacerRegistrationFailed'));
#ifdef PacerPatch
    if not Maintenance(Bootstrap, 'verify', '') then
      RaiseException(CustomMessage('PacerPatchVerifyFailed'));
#endif
  end;
end;

function CleanupInstructions(const Code: Integer): String;
begin
  Result := '';
  if Code <> 22 then
    Result := CustomMessage('PacerCleanupClaude') + #13#10#13#10 + CustomMessage('PacerCleanupClaudeManual') + #13#10#13#10;
  if (Code <> 21) then
    Result := Result + CustomMessage('PacerCleanupRegistrations') + #13#10#13#10;
  Result := Result + CustomMessage('PacerCleanupRuntime') + #13#10#13#10 + CustomMessage('PacerCleanupContinue');
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
        RaiseException(CustomMessage('PacerSilentUninstallStopped'))
      else
        Choice := TaskDialogMsgBox(CustomMessage('PacerCleanupTitle'), Instructions,
          mbError, MB_ABORTRETRYIGNORE, [CustomMessage('PacerRetry'), CustomMessage('PacerContinueUninstall'), CustomMessage('PacerCancel')], 0);
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
        RaiseException(CustomMessage('PacerUninstallCancelled'));
    end;
  end;
end;
