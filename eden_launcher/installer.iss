; Build: python build_launcher.py, then ISCC installer.iss  ->  Output\EdenSetup.exe
[Setup]
AppName=Eden_Project
AppVersion=1.0
DefaultDirName={localappdata}\EdenProject
; per-user install: no admin prompt, and the launcher can write game files without elevation
PrivilegesRequired=lowest
DefaultGroupName=Eden_Project
OutputBaseFilename=EdenSetup
Compression=lzma2
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\EdenLauncher.exe
SetupIconFile=assets\eden.ico

[Files]
Source: "dist\EdenLauncher.exe"; DestDir: "{app}"
; shortcuts point at this .ico directly: Explorer caches exe icons per path and can keep showing an old one
Source: "assets\eden.ico"; DestDir: "{app}"

[Icons]
Name: "{autoprograms}\Eden_Project"; Filename: "{app}\EdenLauncher.exe"; IconFilename: "{app}\eden.ico"
Name: "{autodesktop}\Eden_Project"; Filename: "{app}\EdenLauncher.exe"; IconFilename: "{app}\eden.ico"

[Run]
Filename: "{app}\EdenLauncher.exe"; Description: "Launch Eden_Project"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\game"
Type: files; Name: "{app}\EdenLauncher.exe.old"
Type: files; Name: "{app}\EdenLauncher.exe.new*"
