; =============================================================================
; Hermes Agent Windows 安装包 — Inno Setup 脚本
; 用法: iscc hermes-installer.iss
; =============================================================================

#define AppName "Hermes Agent"
#define AppVersion "0.2.0"
#define AppPublisher "Hermes Community"
#define AppURL "http://localhost:8648"
#define AppExeName "HermesInstaller.exe"

[Setup]
AppId={{3F8A5C91-B2D6-4E3A-A7F1-9C8E2D5A6B4F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=HermesAgent-Setup-v{#AppVersion}
SetupIconFile=assets\icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; Windows 最低版本
MinVersion=10.0.19041

; 架构
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; 权限
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

; 签名（需先申请代码签名证书并配置）
; SignTool=myCustomSignTool

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
chinesesimplified.BeveledLabel={#AppName} v{#AppVersion}

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式:"

[Files]
; 安装向导程序
Source: "..\gui\HermesInstaller\bin\Release\net8.0-windows\publish\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\gui\HermesInstaller\bin\Release\net8.0-windows\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

; 安装脚本 (Phase 1)
Source: "..\scripts\install-hermes.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\wsl-bootstrap.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\setup-mirrors.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\setup-systemd.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\integrate-desktop.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\post-install.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\uninstall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\utils\test-env.ps1"; DestDir: "{app}\scripts\utils"; Flags: ignoreversion

; 桌面增强 (Phase 3)
Source: "..\desktop\shell\register-shell.ps1"; DestDir: "{app}\desktop\shell"; Flags: ignoreversion
Source: "..\desktop\shell\unregister-shell.ps1"; DestDir: "{app}\desktop\shell"; Flags: ignoreversion
Source: "..\desktop\shell\send-to-hermes.ps1"; DestDir: "{app}\desktop\shell"; Flags: ignoreversion

; 文档
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\实机测试报告.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\依赖清单.md"; DestDir: "{app}\docs"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Hermes Web UI"; Filename: "http://localhost:8648"
Name: "{group}\卸载 Hermes Agent"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "启动 Hermes 安装向导"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-File ""{app}\scripts\uninstall.ps1"" -Force"; Flags: runhidden; StatusMsg: "正在清理 Hermes Agent..."

[Code]
// 检测 WSL 是否已安装（含新版 WSL 路径）
function IsWslInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := (Exec('wsl.exe', '--version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0))
         or (Exec('C:\Program Files\WSL\wsl.exe', '--version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0));
end;

function InitializeSetup: Boolean;
begin
  Result := True;

  if not IsWslInstalled then
  begin
    MsgBox('此安装需要 WSL2（Windows Subsystem for Linux）。' + #13#10 +
           '安装向导将自动处理 WSL 安装。' + #13#10 +
           '所有依赖从自建 CDN (121.40.165.216) 下载，无需访问 GitHub。', mbInformation, MB_OK);
  end;
end;
