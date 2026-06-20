#define MyAppName "QueryDock"
#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif
#ifndef MyAppSource
#define MyAppSource "..\build\windows\x64\runner\Release"
#endif
#ifndef MyAppOutput
#define MyAppOutput "..\dist\installer"
#endif

[Setup]
AppId={{7D6E6C61-68CB-4F83-A1D5-40C6B84884CE}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=QueryDock
AppPublisherURL=https://github.com/sanjayVontela/QueryDock
AppSupportURL=https://github.com/sanjayVontela/QueryDock/issues
AppUpdatesURL=https://github.com/sanjayVontela/QueryDock/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir={#MyAppOutput}
OutputBaseFilename=QueryDock-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\db_viewer.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyAppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\db_viewer.exe"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\db_viewer.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\db_viewer.exe"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
