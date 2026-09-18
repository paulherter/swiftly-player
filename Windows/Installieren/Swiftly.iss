; Installationsprogramm fuer Swiftly.
;
; Gebaut mit Inno Setup. Vorher muss `packen.ps1` gelaufen sein — es legt
; unter `Windows\Ablage\Swiftly` die Ablage an, die hier eingepackt wird.
;
;     "C:\Program Files\Inno Setup 7\ISCC.exe" Swiftly.iss
;
; **Ohne Zertifikat.** Der Installer ist nicht signiert; Windows zeigt beim
; ersten Start eine SmartScreen-Warnung. Das laesst sich nur mit einem
; gekauften Zertifikat abstellen, nicht durch etwas im Skript.

#define Name "Swiftly"
#define Fassung "1.0.0"
#define Herausgeber "Paul Herter"
#define Netz "https://github.com/paulherter/swiftly-for-jellyfin"
#define Programm "Swiftly.exe"

[Setup]
AppId={{8E2F1C74-3D9A-4B10-9C7E-5A6B2D8F0E31}
AppName={#Name}
AppVersion={#Fassung}
AppPublisher={#Herausgeber}
AppPublisherURL={#Netz}
AppSupportURL={#Netz}
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir=..\Ablage
OutputBaseFilename=Swiftly-{#Fassung}-Setup
SetupIconFile=..\Mittel\swiftly.ico
UninstallDisplayIcon={app}\bin\{#Programm}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Ohne Adminrechte in den eigenen Ordner, mit in "Programme" — der Nutzer
; entscheidet, nicht wir.
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "deutsch"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopsymbol"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\Ablage\Swiftly\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#Name}"; Filename: "{app}\bin\{#Programm}"
Name: "{autodesktop}\{#Name}"; Filename: "{app}\bin\{#Programm}"; Tasks: desktopsymbol

[Run]
Filename: "{app}\bin\{#Programm}"; Description: "{cm:LaunchProgram,{#Name}}"; Flags: nowait postinstall skipifsilent
