; Swiftly Player Setup (NSIS). Per-user install, no admin rights. Built by Werkzeuge/package-desktop.sh with
; makensis -DVERSION=x.y.z -DSTAGE=<folder with "Swiftly Player.exe" and libmpv-2.dll> -DOUTFILE=<Setup.exe> -DICON=<ico>
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
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
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "German"
!insertmacro MUI_LANGUAGE "English"
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
SectionEnd
