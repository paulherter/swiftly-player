; Installer for Swiftly.
;
; Built with Inno Setup. `package.ps1` must have run first; it creates the
; staging folder under `Windows\Output\Swiftly` that is packed here.
;
;     "C:\Program Files\Inno Setup 7\ISCC.exe" Swiftly.iss
;
; **Unsigned.** The installer has no certificate; Windows shows a SmartScreen
; warning on first run. Only a purchased certificate removes that, nothing in
; this script can.
;
; **Shortcuts point to the launcher** (`{app}\Swiftly.exe`), not to
; `{app}\bin\Swiftly.exe`. On first run Defender scans the app's unsigned
; DLLs, and until then nothing appeared on screen for about 23 s. The launcher
; shows a loading window meanwhile; see `Windows\Launcher\launcher.c`.

#define Name "Swiftly"
#define Fassung "1.0.6"
; Build number, same as `Fassung.bau` in Linux/Sources/SwiftlyLinux/Version.swift.
#define Bau "1"
#define Herausgeber "Paul Herter"
#define Netz "https://github.com/paulherter/swiftly-player"
#define Programm "Swiftly.exe"

[Setup]
AppId={{8E2F1C74-3D9A-4B10-9C7E-5A6B2D8F0E31}
AppName={#Name}
AppVersion={#Fassung}
VersionInfoVersion={#Fassung}.{#Bau}
AppPublisher={#Herausgeber}
AppPublisherURL={#Netz}
AppSupportURL={#Netz}
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir=..\Output
OutputBaseFilename=Swiftly-{#Fassung}-Setup
SetupIconFile=..\Assets\swiftly.ico
UninstallDisplayIcon={app}\{#Programm}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Without admin rights into the user's own folder, with them into "Programme";
; the user decides.
PrivilegesRequiredOverridesAllowed=dialog
; Do not ask again on an update: the first install's choice stays. Otherwise
; a different click would create a second install and a second entry in
; "Apps & Features".
UsePreviousPrivileges=yes
; If Swiftly is still running, Setup warns instead of failing on the locked EXE.
; The app creates both names at startup (`main.swift`).
AppMutex=SwiftlyPlayer,Global\SwiftlyPlayer

[Languages]
Name: "deutsch"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopsymbol"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\Output\Swiftly\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Updating over 1.0.2 would otherwise leave behind the DLLs that `package.ps1`
; now omits; they would not be loaded, but the folder would stay full.
[InstallDelete]
Type: filesandordirs; Name: "{app}\bin\*.dll"

[Icons]
Name: "{group}\{#Name}"; Filename: "{app}\{#Programm}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#Name}"; Filename: "{app}\{#Programm}"; WorkingDir: "{app}"; Tasks: desktopsymbol

[Run]
Filename: "{app}\{#Programm}"; Description: "{cm:LaunchProgram,{#Name}}"; Flags: nowait postinstall skipifsilent
