; Swiftly Player Setup (NSIS). Per-user install, no admin rights. Built by Werkzeuge/package-desktop.sh with
; makensis -DVERSION=x.y.z -DSTAGE=<folder with "Swiftly Player.exe" and libmpv-2.dll> -DOUTFILE=<Setup.exe> -DICON=<ico>
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"
!insertmacro un.GetParameters
!insertmacro un.GetOptions
Name "Swiftly Player"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\Swiftly Player"
InstallDirRegKey HKCU "Software\Swiftly Player" "Dir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Swiftly Player.exe"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
; The usual choice of an uninstaller: keep the user's data (default) or remove it too. Off by default; a silent uninstall
; ("/S") keeps the data unless "/PURGE" is given as well.
UninstPage custom un.PurgePage un.PurgeLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "German"
!insertmacro MUI_LANGUAGE "English"
LangString PurgeText ${LANG_GERMAN} "Deine Anmeldungen, Einstellungen und Downloads bleiben sonst auf diesem PC."
LangString PurgeText ${LANG_ENGLISH} "Otherwise your sign-ins, settings and downloads stay on this PC."
LangString PurgeBox ${LANG_GERMAN} "Auch Anmeldungen, Einstellungen und Downloads entfernen"
LangString PurgeBox ${LANG_ENGLISH} "Also remove sign-ins, settings and downloads"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Swiftly Player"
VIAddVersionKey "FileDescription" "Swiftly Player Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Paul Herter"

; The released 1.0.x app was installed by an Inno Setup installer (AppId below, uninstall entry "<AppId>_is1", per user or all
; users). Setup removes it first, so there is one Swiftly Player afterwards and not two entries in "Apps & features".
; "_?=<dir>" makes the Inno uninstaller run in place and wait; it cannot delete itself then, so its files are removed here.
!define OLD_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E2F1C74-3D9A-4B10-9C7E-5A6B2D8F0E31}_is1"
!macro RemoveOld ROOT VIEW
  SetRegView ${VIEW}
  ReadRegStr $0 ${ROOT} "${OLD_KEY}" "UninstallString"
  ReadRegStr $2 ${ROOT} "${OLD_KEY}" "Inno Setup: App Path"
  ${If} $0 != ""
  ${AndIf} $2 != ""
    ExecWait '$0 /VERYSILENT /NORESTART /SUPPRESSMSGBOXES _?=$2' $1
    Delete "$2\unins000.exe"
    Delete "$2\unins000.dat"
    RMDir "$2"
    DeleteRegKey ${ROOT} "${OLD_KEY}"
  ${EndIf}
!macroend

Section "Install"
  !insertmacro RemoveOld HKCU 64
  !insertmacro RemoveOld HKLM 64
  SetRegView 32
  SetOutPath "$INSTDIR"
  File "${STAGE}\Swiftly Player.exe"
  File "${STAGE}\libmpv-2.dll"
  File "${STAGE}\README.txt"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\Swiftly Player.lnk" "$INSTDIR\Swiftly Player.exe"
  WriteRegStr HKCU "Software\Swiftly Player" "Dir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player" "DisplayName" "Swiftly Player"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player" "Publisher" "Paul Herter"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player" "DisplayIcon" "$INSTDIR\Swiftly Player.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  ; The swiftly:// links (per user): the system starts the app with the link as its argument.
  WriteRegStr HKCU "Software\Classes\swiftly" "" "URL:Swiftly Player"
  WriteRegStr HKCU "Software\Classes\swiftly" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\swiftly\DefaultIcon" "" "$INSTDIR\Swiftly Player.exe,0"
  WriteRegStr HKCU "Software\Classes\swiftly\shell\open\command" "" '"$INSTDIR\Swiftly Player.exe" "%1"'
SectionEnd

Var PurgeCheck
Var Purge

Function un.onInit
  StrCpy $Purge 0
  ${un.GetParameters} $0
  ${un.GetOptions} $0 "/PURGE" $1
  ${IfNot} ${Errors}
    StrCpy $Purge 1
  ${EndIf}
FunctionEnd

Function un.PurgePage
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 24u "$(PurgeText)"
  Pop $0
  ${NSD_CreateCheckbox} 0 30u 100% 12u "$(PurgeBox)"
  Pop $PurgeCheck
  ${If} $Purge == 1
    ${NSD_Check} $PurgeCheck
  ${EndIf}
  nsDialogs::Show
FunctionEnd

Function un.PurgeLeave
  ${NSD_GetState} $PurgeCheck $Purge
FunctionEnd

Section "Uninstall"
  Delete "$INSTDIR\Swiftly Player.exe"
  Delete "$INSTDIR\libmpv-2.dll"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Swiftly Player.lnk"
  DeleteRegKey HKCU "Software\Classes\swiftly"
  DeleteRegKey HKCU "Software\Swiftly Player"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiftly Player"
  ; The single-instance lock is never user data: always gone (the folder only when nothing else is in it).
  Delete "$LOCALAPPDATA\Swiftly\swiftly-desktop.lock"
  RMDir "$LOCALAPPDATA\Swiftly"
  ; The user's data only on request: settings, library, downloads, secrets file, and the Credential Manager entries the app
  ; made (target "<name>.de.swiftly.player": aktiveArt..., konten..., konten.plex...).
  ${If} $Purge == 1
    RMDir /r "$APPDATA\Swiftly"
    RMDir /r "$LOCALAPPDATA\Swiftly"
    nsExec::Exec `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "cmdkey /list | ForEach-Object { if ($$_ -match 'target=(\S+\.de\.swiftly\.player)\s*$$') { cmdkey /delete:$$($$Matches[1]) | Out-Null } }"`
    Pop $0
  ${EndIf}
SectionEnd
