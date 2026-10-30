; REMOHELP PRO 相談員プログラムのセットアップ（2026-10-30 社長の確定見本「1 インストール」の5画面）。
;   ようこそ → 使用許諾契約 → インストール先 → インストール中 → 完了（起動する）
;
; 🔴 崩さない: 製品名を主役にする。32ビット・64ビットの話は画面に出さない（裏で合わせる）。
; 🔴 遠隔操作の部品（操作アプリ）も一緒に入れる。PC に合わせて 64ビット版（MSI）か 32ビット版を
;    サーバーから受け取る。⚠ 失敗してもセットアップは止めない（あとで操作アプリのページから入れられる）。
; 🔴 インストール先は利用者が書き換えられるようにする（Permissions: users-modify）。
;    起動のときの自動更新が、管理者の「はい」を出さずに実行ファイルを差し替えるため（src/update.rs）。
;
; 組み立て: iscc /DAppVersion=1.0.5 [/DDev=1] /DSrcExe=..\..\ConsoleOut\x.exe console.iss
; ⚠ 試験用（Dev）は別の製品として入る（AppId・フォルダ・実行ファイル名が違う＝本番と並べて入れられる）。
;   実行ファイル名に dev が入っていると試験用サーバーにつながる（main.rs）。

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SrcExe
  #define SrcExe "remohelppro-console.exe"
#endif

#ifdef Dev
  #define AppId "{{A3B1C90A-5A3B-45BA-9923-F84FAA8B6228}"
  #define AppName "REMOHELP PRO 相談員プログラム（試験用）"
  #define ShortName "REMOHELP PRO 相談員（試験用）"
  #define ExeName "remohelppro-console-dev.exe"
  #define Server "https://dev.remohelppro.jp"
  #define Scheme "remohelppro-dev"
  #define OutName "remohelppro-console-dev-setup"
#else
  #define AppId "{{EABEDDDE-0AE7-433A-822D-D10AA7B72CDB}"
  #define AppName "REMOHELP PRO 相談員プログラム"
  #define ShortName "REMOHELP PRO 相談員"
  #define ExeName "remohelppro-console.exe"
  #define Server "https://svr.remohelppro.jp"
  #define Scheme "remohelppro"
  #define OutName "remohelppro-console-setup"
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=株式会社リモシス
AppPublisherURL=https://remohelppro.jp/
VersionInfoVersion={#AppVersion}
VersionInfoProductName=REMOHELP PRO
VersionInfoDescription={#AppName} セットアップ
DefaultDirName={autopf}\{#ShortName}
DefaultGroupName={#ShortName}
DisableProgramGroupPage=yes
; 64ビットの Windows でも「C:\Program Files」に入れる（見本どおり）。中身は 32/64 共通の1個
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
LicenseFile=license.txt
WizardStyle=classic
WizardImageFile=wizard.bmp
WizardSmallImageFile=wizard-small.bmp
SetupIconFile=..\..\res\icon.ico
UninstallDisplayIcon={app}\{#ExeName}
UninstallDisplayName={#AppName}
OutputDir=..\..\ConsoleOut
OutputBaseFilename={#OutName}-{#AppVersion}
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"

[Messages]
ja.WelcomeLabel1={#AppName}%nセットアップへようこそ
ja.WelcomeLabel2=このプログラムで、認証コードの発行から遠隔操作、常駐PC への接続まで、お客様のサポートをすべて行えます。%n%n続けるには［次へ］を押してください。
ja.FinishedHeadingLabel=セットアップが完了しました
ja.FinishedLabel={#AppName}をインストールしました。デスクトップの「{#ShortName}」から開けます。
ja.ClickFinish=

[Tasks]
Name: "desktopicon"; Description: "デスクトップにアイコンを作る"

[Dirs]
Name: "{app}"; Permissions: users-modify

[Files]
Source: "{#SrcExe}"; DestDir: "{app}"; DestName: "{#ExeName}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#ShortName}"; Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#ShortName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{#AppName}を起動する"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
Type: files; Name: "{app}\*.old"
Type: files; Name: "{app}\*.new"
Type: filesandordirs; Name: "{app}\*.WebView2"

[Code]
{ 遠隔操作の部品が入っているか。操作アプリは入ると独自のスキーム（remohelppro://）を登録する }
function ViewerInstalled(): Boolean;
begin
  Result := RegKeyExists(HKCR, '{#Scheme}');
end;

procedure InstallViewer();
var
  Url, FileName, Tmp: String;
  Code: Integer;
  Ok: Boolean;
begin
  if ViewerInstalled() then
    exit;
  if IsWin64 then begin
    Url := '{#Server}/download/remohelppro-operator-setup.msi';
    FileName := 'remohelppro-operator-setup.msi';
  end else begin
    Url := '{#Server}/download/remohelppro-operator-x86-install.exe';
    FileName := 'remohelppro-operator-x86-install.exe';
  end;
  WizardForm.StatusLabel.Caption := '遠隔操作の部品を入れています…';
  Ok := False;
  try
    DownloadTemporaryFile(Url, FileName, '', nil);
    Tmp := ExpandConstant('{tmp}\' + FileName);
    if IsWin64 then
      Ok := Exec(ExpandConstant('{sys}\msiexec.exe'), '/i "' + Tmp + '" /qn /norestart', '', SW_HIDE, ewWaitUntilTerminated, Code) and ((Code = 0) or (Code = 3010))
    else
      Ok := Exec(Tmp, '--silent-install', '', SW_HIDE, ewWaitUntilTerminated, Code);
  except
    Ok := False;
  end;
  if (not Ok) and (not WizardSilent) then
    MsgBox('遠隔操作の部品を入れられませんでした。' #13#10 +
      'インターネットにつながっているか確かめてください。' #13#10#13#10 +
      '相談員プログラムはこのまま使えます。遠隔操作の部品は、あとで「リンク」→「操作アプリの準備」から入れられます。',
      mbInformation, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    InstallViewer();
end;
