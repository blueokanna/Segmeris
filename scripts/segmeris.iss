#ifndef ReleaseVersion
  #error ReleaseVersion must match the validated pubspec version
#endif
#define Bundle "..\build\windows\x64\runner\Release"

[Setup]
AppId=com.blue.segmeris
AppName=Segmeris
AppVersion={#ReleaseVersion}
VersionInfoVersion={#ReleaseVersion}.0
AppPublisher=Segmeris
AppPublisherURL=https://github.com/blueokanna/Segmeris
DefaultDirName={localappdata}\Programs\Segmeris
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
DisableProgramGroupPage=yes
Compression=lzma2/fast
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\segmeris.exe
OutputDir=..\dist\windows
OutputBaseFilename=Segmeris-windows-x64-setup

[Files]
Source: "{#Bundle}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Segmeris"; Filename: "{app}\segmeris.exe"
