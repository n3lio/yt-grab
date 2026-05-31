; =========================================================
;  yt-grab  —  Inno Setup installer script
;  Généré pour n3lio/yt-grab
;  Prérequis (côté Windows) :
;    - avoir déjà buildé yt-grab.exe via build.bat
;    - Inno Setup 6.x installé  https://jrsoftware.org/isinfo.php
;  Usage : double-cliquer "build-installer.bat"
; =========================================================

#define AppName      "YouTube Grabber by n3lio"
#define AppShortName "YouTube Grabber"
#define AppVersion   "2.0.7"
#define AppPublisher "n3lio"
#define AppURL       "https://github.com/n3lio/yt-grab"
#define AppExe       "yt-grab.exe"

[Setup]
AppId={{F3A2B8C1-4D7E-4F9A-B3C2-1A2B3C4D5E6F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppShortName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
; Compression maximale
Compression=lzma2/ultra64
SolidCompression=yes
; x64 ou x32 auto
ArchitecturesInstallIn64BitMode=x64
; Icône de l'installer lui-même
SetupIconFile=yt-grab.ico
; Pas besoin de droits admin si on installe dans {autopf}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Sortie
OutputDir=dist
OutputBaseFilename=yt-grab-{#AppVersion}-setup
; Désinstallation propre
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
; WizardStyle moderne (Inno 6+)
WizardStyle=modern

[Languages]
Name: "french";  MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon";    Description: "Créer un raccourci sur le &Bureau";          GroupDescription: "Raccourcis supplémentaires :"; Flags: unchecked
Name: "startmenuicon";  Description: "Créer un raccourci dans le &Menu Démarrer";  GroupDescription: "Raccourcis supplémentaires :"; Flags: checkedonce

[Files]
; L'exe principal (déjà buildé par build.bat)
Source: "{#AppExe}";    DestDir: "{app}"; Flags: ignoreversion
; Icône
Source: "yt-grab.ico";  DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Menu Démarrer
Name: "{group}\{#AppName}";           Filename: "{app}\{#AppExe}"; IconFilename: "{app}\yt-grab.ico"; Tasks: startmenuicon
Name: "{group}\Désinstaller {#AppName}"; Filename: "{uninstallexe}";                                    Tasks: startmenuicon
; Bureau
Name: "{autodesktop}\{#AppName}";     Filename: "{app}\{#AppExe}"; IconFilename: "{app}\yt-grab.ico"; Tasks: desktopicon

[Run]
; Proposition de lancer l'app après installation
Filename: "{app}\{#AppExe}"; Description: "Lancer {#AppName} maintenant"; Flags: nowait postinstall skipifsilent
