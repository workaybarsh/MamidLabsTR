; MamidLabs tek tikla kurulum sihirbazi (Inno Setup 6).
;
; Derleme: iscc packaging\windows\mamidlabs.iss   -> dist\MamidLabs_Setup.exe
; GitHub Actions: .github/workflows/kurulum-paketi.yml
;
; Sihirbaz program dosyalarini {app}\kurulum-kaynak altina acar ve kurulumun asil
; isini scripts\setup-run.ps1'e birakir: on kosullar, altyapi, secilen profilin
; modelleri, kendi model/API tercihi, smoke testi ve ozet. Sihirbaz sayfalari:
; karsilama, lisans, klasor, profil raporu, profil secimi, kendi modellerin, API,
; ek gorevler, hazir, kurulum, ozet, bitis.

; Surumun tek kaynagi. CI etiketi (v1.0.0) bu degerle karsilastirir; CHANGELOG.md'de
; ayni numarali bir bolum olmalidir.
#define MyAppVersion "1.0.8"
#define MyAppName "MamidLabs"
#define MyAppPublisher "workaybarsh"
#define MyAppURL "https://github.com/workaybarsh/MamidLabsTR"

[Setup]
AppId={{56CF14A8-57AF-4EEB-A520-937212F0B365}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Kurulum
VersionInfoProductName={#MyAppName}

; Kullanici basina programlarin standart yeri: PrivilegesRequired=lowest oldugu icin
; {autopf} = %LOCALAPPDATA%\Programs. Program Files kullanilamaz: uygulama kendi kokune
; ayar/log/model yazar, orasi yonetici olmadan yazilamaz. Guncellemeler
; UsePreviousAppDir ile mevcut kurulum klasorune yapilir. Kullanici klasoru degistirebilir.
DefaultDirName={autopf}\MamidLabs
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE

OutputDir=..\..\dist
OutputBaseFilename=MamidLabs_Setup

SetupIconFile=..\..\assets\icons\mamidlabs.ico
WizardImageFile=..\..\assets\installer\wizard_side.bmp,..\..\assets\installer\wizard_side@2x.bmp
WizardSmallImageFile=..\..\assets\installer\wizard_small.bmp,..\..\assets\installer\wizard_small@2x.bmp
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\assets\icons\mamidlabs.ico

WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
Compression=lzma2
SolidCompression=yes
DisableWelcomePage=no
; Paket yalnizca birkac MB; asil yer altyapiya (PowerShell, llama.cpp, torch, ComfyUI) gider.
; Klasor sayfasi gercek asgariyi gostersin ve yer yoksa uyarsin. Modeller ayrica
; LITE'ta ~36 GB, Qwen3.8 27B'de ~52 GB'tir (SelectDirLabel3).
ExtraDiskSpaceRequired=12884901888
DisableReadyMemo=no
Uninstallable=yes
CreateUninstallRegKey=yes

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Messages]
SetupWindowTitle=MamidLabs Kurulum Sihirbazı
WelcomeLabel1=MamidLabs'e hoş geldin
SelectDirDesc=MamidLabs ve modelleri nereye kurulsun?
SelectDirLabel3=Modeller dahil LITE için ~58 GB, Qwen3.8 27B için ~75 GB boş yer gerekir; hızlı bir SSD seç.
FinishedHeadingLabel=MamidLabs kurulumu tamamlandı
FinishedLabelNoIcons=MamidLabs bilgisayarına kuruldu. Masaüstündeki MamidLabs kısayoluyla açabilirsin.

[Tasks]
Name: "smoketest"; Description: "Kurulum sonunda smoke testi çalıştır (sohbet, belge, görsel, fotoğraf düzenleme, model geçişi) — uzun sürebilir (görsel/video adımları dahil onlarca dakika), model dosyaları indirilmediyse atlanır"; GroupDescription: "Doğrulama:"; Flags: unchecked
Name: "ocr"; Description: "OCR'ı da kur — fotoğraf, taranmış bir sayfa ya da ekran görüntüsü gönderdiğinde içindeki yazıyı okuyup metne çevirir, örneğin bir faturayı ya da el yazısı bir notu fotoğraflatıp okutabilirsin; yaklaşık 3 GB, önerilir"; GroupDescription: "İsteğe bağlı:"

[Files]
; Program kaynagi. setup-run.ps1 bunu install-mamidlabs.ps1 -Source olarak kullanir;
; guncellemede ayni klasor yeniden yazilir.
Source: "..\..\qwen-desktop.ps1"; DestDir: "{app}\kurulum-kaynak"; Flags: ignoreversion
Source: "..\..\launch-qwen-desktop.vbs"; DestDir: "{app}\kurulum-kaynak"; Flags: ignoreversion
Source: "..\..\README.md"; DestDir: "{app}\kurulum-kaynak"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}\kurulum-kaynak"; Flags: ignoreversion
Source: "..\..\agent\*"; DestDir: "{app}\kurulum-kaynak\agent"; Excludes: "__pycache__\*,*.pyc"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\scripts\*"; DestDir: "{app}\kurulum-kaynak\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\assets\*"; DestDir: "{app}\kurulum-kaynak\assets"; Excludes: "installer\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\requirements\*"; DestDir: "{app}\kurulum-kaynak\requirements"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\docs\kurulum.md"; DestDir: "{app}\kurulum-kaynak\docs"; Flags: ignoreversion
; Profil raporu kurulumdan ONCE, gecici klasorden calisir.
Source: "..\..\scripts\profile-report.ps1"; Flags: dontcopy
Source: "..\..\agent\profiles.json"; Flags: dontcopy

[Run]
Filename: "{app}\launch-qwen-desktop.vbs"; Description: "MamidLabs'i şimdi aç"; Flags: postinstall shellexec nowait skipifsilent; Check: LauncherExists

[UninstallDelete]
; Asil temizligi scripts\uninstall-mamidlabs.ps1 yapar (CurUninstallStepChanged): surecleri
; durdurur, modelleri/onbellekleri/sohbetleri, bu kuruluma ait masaustu kisayolunu ve
; MamidLabs'in kurdugu on kosullari siler. Asagisi betik calisamazsa diye yedektir.
; Masaustu kisayolu burada silinmez: baska bir kopyanin kisayolu olabilir.
Type: filesandordirs; Name: "{app}\kurulum-kaynak"
Type: filesandordirs; Name: "{app}\agent"
Type: filesandordirs; Name: "{app}\scripts"
Type: filesandordirs; Name: "{app}\assets"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\llama.cpp"
Type: filesandordirs; Name: "{app}\venv"
Type: filesandordirs; Name: "{app}\tools"
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\qwen-desktop.ps1"
Type: files; Name: "{app}\launch-qwen-desktop.vbs"
Type: files; Name: "{app}\README.md"
Type: files; Name: "{app}\LICENSE"
; Klasor kullanicinin sectigi, baska dosyalar iceren bir yer olabilir; yalnizca bossa silinir.
Type: dirifempty; Name: "{app}"

[Code]
var
  ReportPage: TOutputMsgMemoWizardPage;
  ProfilePage: TInputOptionWizardPage;
  OwnModelPage: TInputFileWizardPage;
  ApiPage: TInputOptionWizardPage;
  SummaryPage: TOutputMsgMemoWizardPage;
  ReportedDir: String;
  SetupExitCode: Integer;
  InstallRunning: Boolean;
  InstallCancelled: Boolean;
  { Inno'nun kendi Iptal dugmesi, ssPostInstall'da CurStepChanged calisirken
    CancelButtonClick kancasini tetiklemez (PumpMessages dongusu icinde bile). Bu yuzden
    kurulum surerken onun yerine normal bir OnClick'e bagli kendi dugmemiz gosterilir. }
  CustomCancelButton: TNewButton;

const
  OptLite = 0;
  { FLASH ve MAX birebir aynı dosyaları kullanır (agent/profiles.json'da "target" yolları
    özdeş); yalnızca çalışma zamanı ayarları (reasoning effort/predict) farklıdır. Kurulumda
    tek "PRO" (Qwen3.8 27B) seçeneği vardır ve indirme 'flash' kataloğuyla yapılır. FLASH/MAX
    geçişi uygulamanın alt çubuğundan yapılır (agent/model-registry.ps1). }
  OptQwen38 = 1;
  OptLater = 2;
  OptOwn = 3;

{ CurStepChanged icindeki Abort yalnizca prosedurun geri kalanini durdurur; Inno'nun adim
  makinesi ssPostInstall'dan sonra Ozet/Bitis sayfalarina gecmeye devam eder. Iptal edilen
  kurulumda geri alma bittikten hemen sonra surec dogrudan sonlandirilir. }
procedure ExitProcess(uExitCode: Cardinal);
  external 'ExitProcess@kernel32.dll stdcall';

function PowerShellExe: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function LauncherExists: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\launch-qwen-desktop.vbs'));
end;

procedure CustomCancelButtonClick(Sender: TObject); forward;

function SelectedProfile: String;
begin
  case ProfilePage.SelectedValueIndex of
    OptLite: Result := 'lite';
    OptQwen38: Result := 'flash';
  else
    Result := 'none';
  end;
end;

procedure InitializeWizard;
var
  NL: String;
begin
  NL := Chr(13) + Chr(10);

  { Karsilama sayfasi: buyuk baslik ve kisa tanitim. }
  WizardForm.WelcomeLabel1.Caption := 'MamidLabs''e hoş geldin';
  WizardForm.WelcomeLabel1.Font.Size := 18;
  WizardForm.WelcomeLabel1.Font.Style := [fsBold];
  WizardForm.WelcomeLabel1.AutoSize := False;
  WizardForm.WelcomeLabel1.Top := ScaleY(22);
  WizardForm.WelcomeLabel1.Height := ScaleY(62);

  WizardForm.WelcomeLabel2.Caption :=
    'Tamamen yerel çalışan, çok modlu yapay zekâ çalışma alanı.' + NL + NL +
    'Sohbet, web araması, belge, OCR, görsel anlama, görsel ve video üretimi, ' +
    'fotoğraf düzenleme tek pencerede; modeller kendi ekran kartında çalışır.' + NL + NL +
    'Sihirbaz önce bilgisayarını ölçüp uygun profili önerir. Modelleri şimdi ' +
    'indirebilir, daha sonraya bırakabilir ya da kendi modelini veya API hesabını ' +
    'kullanabilirsin.' + NL + NL +
    'Devam etmek için Sonraki''ye tıkla.';
  WizardForm.WelcomeLabel2.Font.Size := 10;
  WizardForm.WelcomeLabel2.AutoSize := False;
  WizardForm.WelcomeLabel2.Top := ScaleY(100);
  WizardForm.WelcomeLabel2.Height := ScaleY(190);

  ReportPage := CreateOutputMsgMemoPage(wpSelectDir,
    'Profil raporu', 'Bu bilgisayar hangi profili çalıştırabilir?',
    'Ekran kartı, bellek ve disk ölçüldü. Önerilen profil bir sonraki sayfada işaretli gelir.', '');

  ProfilePage := CreateInputOptionPage(ReportPage.ID,
    'Model profili', 'Hangi modeller kurulsun?',
    'Profil dosyaları kurulumun sonunda indirilir ve boyutları doğrulanır. İstersen şimdi indirme; ' +
    'uygulamada Profiller → Profil yöneticisi → Eksikleri indir ile istediğin zaman kurabilirsin.',
    True, False);
  ProfilePage.Add('LITE — 8 GB ekran kartı (Qwen3.5 9B, ~36 GB indirme)');
  ProfilePage.Add('PRO — 16 GB ekran kartı (Qwen3.8 27B, ~52 GB indirme)');
  ProfilePage.Add('Şimdi model indirme — profili daha sonra kuracağım');
  ProfilePage.Add('Kendi modelimi ya da API hesabımı kullanacağım');
  ProfilePage.SelectedValueIndex := OptLite;

  OwnModelPage := CreateInputFilePage(ProfilePage.ID,
    'Kendi modellerin', 'Kullanmak istediğin model dosyalarını seç (hepsi isteğe bağlı).',
    'Dosyalar kopyalanmaz, bulundukları yerde kullanılır. Boş bıraktıklarını daha sonra uygulamadan ekleyebilirsin.');
  OwnModelPage.Add('Dil modeli (.gguf):', 'GGUF dil modeli|*.gguf|Tüm dosyalar|*.*', '.gguf');
  OwnModelPage.Add('Görsel modeli — Krea 2 Turbo (.safetensors veya .gguf):', 'Görsel modeli|*.safetensors;*.gguf|Tüm dosyalar|*.*', '');
  OwnModelPage.Add('Video modeli — Wan 2.2 TI2V 5B (.safetensors):', 'Video modeli|*.safetensors|Tüm dosyalar|*.*', '.safetensors');

  ApiPage := CreateInputOptionPage(OwnModelPage.ID,
    'API hesabı', 'OpenAI, Claude, Gemini ya da DeepSeek hesabını bağla.',
    'Anahtar kurulumda istenmez. Uygulama ilk açılışta API bağlantıları penceresini açar: ' +
    '"Hesabına gir, anahtar al" sağlayıcının anahtar sayfasını açar, "Doğrula ve modelleri getir" ' +
    'anahtarı dener ve hesabındaki modelleri listeler. Anahtar Windows hesabına bağlı şifreli saklanır.',
    False, False);
  ApiPage.Add('İlk açılışta API bağlantıları penceresini aç');
  ApiPage.Values[0] := False;

  SummaryPage := CreateOutputMsgMemoPage(wpInstalling,
    'Kurulum özeti', 'Adımların sonucu ve smoke testi',
    'Özetin bir kopyası kurulum klasöründe logs\kurulum-ozeti.txt dosyasındadır.', '');

  { Kurulum surerken Inno'nun Iptal dugmesinin yerine gosterilir: ayni konum ve boyut,
    normal bir OnClick. Metin sabittir; InitializeWizard aninda CancelButton.Caption
    henuz atanmamis olur. }
  CustomCancelButton := TNewButton.Create(WizardForm);
  CustomCancelButton.Parent := WizardForm;
  CustomCancelButton.Caption := 'İptal';
  CustomCancelButton.Left := WizardForm.CancelButton.Left;
  CustomCancelButton.Top := WizardForm.CancelButton.Top;
  CustomCancelButton.Width := WizardForm.CancelButton.Width;
  CustomCancelButton.Height := WizardForm.CancelButton.Height;
  CustomCancelButton.Anchors := WizardForm.CancelButton.Anchors;
  CustomCancelButton.OnClick := @CustomCancelButtonClick;
  CustomCancelButton.Visible := False;
end;

{ Profil raporu: klasor secildikten sonra (bos disk o surucuden olculur) calisir. }
procedure RunProfileReport;
var
  ReportFile, RecommendFile, Params, Recommended: String;
  RecommendedRaw: AnsiString;
  Lines: TArrayOfString;
  Text: String;
  I, ResultCode: Integer;
begin
  if ReportedDir = WizardDirValue then Exit;
  ReportedDir := WizardDirValue;
  ExtractTemporaryFile('profile-report.ps1');
  ExtractTemporaryFile('profiles.json');
  ReportFile := ExpandConstant('{tmp}\profil-raporu.txt');
  RecommendFile := ExpandConstant('{tmp}\profil-onerisi.txt');
  Params := '-NoProfile -ExecutionPolicy Bypass -File ' + AddQuotes(ExpandConstant('{tmp}\profile-report.ps1')) +
    ' -Root ' + AddQuotes(WizardDirValue) +
    ' -Catalog ' + AddQuotes(ExpandConstant('{tmp}\profiles.json')) +
    ' -OutFile ' + AddQuotes(ReportFile) + ' -RecommendFile ' + AddQuotes(RecommendFile);
  ReportPage.RichEditViewer.Lines.Text := 'Donanım ölçülüyor…';
  WizardForm.Refresh;
  if not Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
  begin
    ReportPage.RichEditViewer.Lines.Text := 'Profil raporu oluşturulamadı. Profili kendin seçebilirsin.';
    Exit;
  end;
  Text := '';
  if LoadStringsFromFile(ReportFile, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      Text := Text + Lines[I] + #13#10;
  ReportPage.RichEditViewer.Lines.Text := Text;
  if LoadStringFromFile(RecommendFile, RecommendedRaw) then
  begin
    Recommended := Trim(String(RecommendedRaw));
    if (Recommended = 'flash') or (Recommended = 'max') then ProfilePage.SelectedValueIndex := OptQwen38
    else if Recommended = 'lite' then ProfilePage.SelectedValueIndex := OptLite
    else ProfilePage.SelectedValueIndex := OptOwn;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = ReportPage.ID then RunProfileReport;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = OwnModelPage.ID then
    Result := ProfilePage.SelectedValueIndex <> OptOwn
  else if PageID = ApiPage.ID then
    Result := ProfilePage.SelectedValueIndex < OptLater
  else if PageID = wpSelectTasks then
    { Smoke testi ve OCR yalnizca model indirilen profillerde anlamli. }
    Result := ProfilePage.SelectedValueIndex >= OptLater;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  I: Integer;
begin
  Result := True;
  if CurPageID = OwnModelPage.ID then
    for I := 0 to 2 do
      if (OwnModelPage.Values[I] <> '') and not FileExists(OwnModelPage.Values[I]) then
      begin
        MsgBox('Dosya bulunamadı: ' + OwnModelPage.Values[I], mbError, MB_OK);
        Result := False;
        Exit;
      end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Lines: String;
begin
  Lines := MemoDirInfo + NewLine + NewLine + 'Profil:' + NewLine + Space + ProfilePage.CheckListBox.ItemCaption[ProfilePage.SelectedValueIndex];
  if ProfilePage.SelectedValueIndex = OptOwn then
  begin
    if OwnModelPage.Values[0] <> '' then Lines := Lines + NewLine + Space + 'Dil modeli: ' + OwnModelPage.Values[0];
    if OwnModelPage.Values[1] <> '' then Lines := Lines + NewLine + Space + 'Görsel modeli: ' + OwnModelPage.Values[1];
    if OwnModelPage.Values[2] <> '' then Lines := Lines + NewLine + Space + 'Video modeli: ' + OwnModelPage.Values[2];
  end;
  if (ProfilePage.SelectedValueIndex >= OptLater) and ApiPage.Values[0] then
    Lines := Lines + NewLine + Space + 'İlk açılışta API bağlantıları penceresi açılacak';
  { Gorevler sayfasi (smoke testi, OCR) yalnizca model indirilen profillerde gosterilir ve
    uygulanir; diger seceneklerde ozette de listelenmez. }
  if (ProfilePage.SelectedValueIndex < OptLater) and (MemoTasksInfo <> '') then
    Lines := Lines + NewLine + NewLine + MemoTasksInfo;
  { Hazir sayfasi metni sarmaz; uzun satir sagdan kesiliyordu. Her cumle kendi satirinda. }
  Lines := Lines + NewLine + NewLine + 'Bu kurulum internet bağlantısı gerektirir (PowerShell 7, ' +
    'llama.cpp, Python paketleri ve ComfyUI indirilir).' +
    NewLine + 'Kurulum arka planda ilerler; bu pencere ilerlemeyi gösterir.' +
    NewLine + 'Python, Git, 7-Zip ve VC++ Redistributable yoksa winget ile kurulur.';
  if ProfilePage.SelectedValueIndex < OptLater then
    Lines := Lines + NewLine + 'Model indirme bağlantı hızına göre 30-90 dakika sürebilir.'
  else
    Lines := Lines + NewLine + 'Model indirilmediği için kurulum yaklaşık 10-15 dakika sürer.';
  Result := Lines;
end;

function BuildSetupParams: String;
var
  P: String;
begin
  P := '-NoProfile -ExecutionPolicy Bypass -File ' + AddQuotes(ExpandConstant('{app}\kurulum-kaynak\scripts\setup-run.ps1')) +
    ' -Root ' + AddQuotes(ExpandConstant('{app}')) +
    ' -Source ' + AddQuotes(ExpandConstant('{app}\kurulum-kaynak')) +
    ' -Profile ' + SelectedProfile + ' -InstallPrereqs -FromWizard';
  if ProfilePage.SelectedValueIndex < OptLater then
  begin
    P := P + ' -DownloadModels';
    if WizardIsTaskSelected('smoketest') then P := P + ' -SmokeTest';
    if WizardIsTaskSelected('ocr') then P := P + ' -Ocr';
  end;
  if ProfilePage.SelectedValueIndex = OptOwn then
  begin
    if OwnModelPage.Values[0] <> '' then P := P + ' -LlmPath ' + AddQuotes(OwnModelPage.Values[0]);
    if OwnModelPage.Values[1] <> '' then P := P + ' -ImageModelPath ' + AddQuotes(OwnModelPage.Values[1]);
    if OwnModelPage.Values[2] <> '' then P := P + ' -VideoModelPath ' + AddQuotes(OwnModelPage.Values[2]);
  end;
  if (ProfilePage.SelectedValueIndex >= OptLater) and ApiPage.Values[0] then P := P + ' -OpenApiSettings';
  Result := P;
end;

type
  { Gercek Win32 MSG yapisinin duz (ic ice olmayan) karsiligi; PeekMessage/
    DispatchMessage bunu POINT'in x/y alanlarina kadar aynen bekler. }
  TMsg = record
    hwnd: Longint;
    message: Cardinal;
    wParam: Longint;
    lParam: Longint;
    time: Cardinal;
    ptX: Longint;
    ptY: Longint;
  end;

function PeekMessageW(var lpMsg: TMsg; hWnd: Longint; wMsgFilterMin, wMsgFilterMax, wRemoveMsg: Cardinal): Boolean;
  external 'PeekMessageW@user32.dll stdcall';
function TranslateMessage(const lpMsg: TMsg): Boolean;
  external 'TranslateMessage@user32.dll stdcall';
function DispatchMessageW(const lpMsg: TMsg): Longint;
  external 'DispatchMessageW@user32.dll stdcall';

{ setup-run.ps1 ewNoWait ile baslatilir ve bekleme suresince mesaj kuyrugu burada elle
  pompalanir. Exec(..., ewWaitUntilTerminated) sihirbazin mesaj dongusunu durdurur,
  pencere "Yanit vermiyor" olur ve Iptal dugmesi calismaz. }
procedure PumpMessages;
var
  Msg: TMsg;
begin
  while PeekMessageW(Msg, 0, 0, 0, 1) do
  begin
    TranslateMessage(Msg);
    DispatchMessageW(Msg);
  end;
end;

{ setup-run.ps1 sureci hala calisiyor mu? Surec bitis bayragini yazmadan sonlanirsa
  sihirbaz sonsuza kadar beklemesin diye kullanilir. Exec stdout yakalamadigi icin
  tasklist | find cikis kodu okunur (PID bulunduysa 0). }
function ProcessIsRunning(const Pid: String): Boolean;
var
  ResultCode: Integer;
  Params: String;
begin
  Params := '/C tasklist /FI "PID eq ' + Pid + '" /NH | find "' + Pid + '" >nul';
  if not Exec(ExpandConstant('{cmd}'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    { tasklist bile baslatilamadiysa temkinli ol: surec hala calisiyor varsay -
      dongu zaten DoneFlag/InstallCancelled ile de cikabilir, sonsuza kalmaz. }
    Result := True;
    Exit;
  end;
  Result := (ResultCode = 0);
end;

{ X ile kapatma / Alt+F4 gibi diger iptal yollari icin; InstallRunning disinda bir sey
  yapmaz. Kurulum sirasindaki Iptal tiklamasi CustomCancelButtonClick ile islenir.
  Onaylanan iptalin sonlandirma/geri alma isi CurStepChanged'in bekleme dongusunden
  ciktiktan sonra yapilir. }
procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if not InstallRunning then Exit;
  Confirm := False;
  Cancel := False;
  if InstallCancelled then Exit;
  if MsgBox('Kurulum iptal edilsin mi? O zamana kadar indirilen/kurulan her şey ' +
    '(modeller dahil) kaldırılacak.' + #13#10#13#10 + 'İptal edilsin mi?',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    InstallCancelled := True;
end;

{ Kurulum surerken Inno'nun Iptal dugmesinin yerini alir (bkz. CustomCancelButton). }
procedure CustomCancelButtonClick(Sender: TObject);
begin
  if not InstallRunning then Exit;
  if InstallCancelled then Exit;
  if MsgBox('Kurulum iptal edilsin mi? O zamana kadar indirilen/kurulan her şey ' +
    '(modeller dahil) kaldırılacak.' + #13#10#13#10 + 'İptal edilsin mi?',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    InstallCancelled := True;
end;

{ Kurulum betigi gizli calistigi icin ilerleme sihirbazda gosterilir. setup-run.ps1'in
  yazdigi 3 satirlik ilerleme dosyasini (adim no / toplam / adim adi, bkz.
  Set-InstallProgress) okuyup FilenameLabel'i ve ilerleme cubugunu gunceller. Dosya
  henuz yoksa ya da bozuksa bir sey yapmaz; onceki durum ekranda kalir. }
procedure UpdateInstallProgress(const ProgressFile: String);
var
  PLines: TArrayOfString;
  StepIdx, StepTotal: Integer;
begin
  if not LoadStringsFromFile(ProgressFile, PLines) then Exit;
  if GetArrayLength(PLines) < 3 then Exit;
  StepIdx := StrToIntDef(PLines[0], 0);
  StepTotal := StrToIntDef(PLines[1], 0);
  if StepTotal <= 0 then Exit;
  WizardForm.FilenameLabel.Caption := PLines[2] + ' (' + PLines[0] + '/' + PLines[1] + ')';
  WizardForm.ProgressGauge.Style := npbstNormal;
  WizardForm.ProgressGauge.Max := StepTotal;
  { StepIdx'inci adim henuz calisiyor; cubuk tamamlanan adim kadar dolar ve son adimda
    erken %100 gostermez. }
  WizardForm.ProgressGauge.Position := StepIdx - 1;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SummaryFile, DoneFlag, PidFile, ProgressFile, PidText, KillParams, RollbackScript, RollbackParams, SetupPid: String;
  PidAnsi: AnsiString;
  Lines: TArrayOfString;
  Text: String;
  I, KillResult, RollbackResult, Ticks: Integer;
  Started, ProcessExited: Boolean;
begin
  if CurStep <> ssPostInstall then Exit;
  WizardForm.StatusLabel.Caption := 'MamidLabs kuruluyor…';
  WizardForm.FilenameLabel.Caption := 'Bu adım uzun sürebilir. İstersen İptal''e basıp o zamana kadar kurulanları kaldırabilirsin.';
  WizardForm.ProgressGauge.Style := npbstMarquee;

  DoneFlag := ExpandConstant('{app}\logs\kurulum-tamam.flag');
  PidFile := ExpandConstant('{app}\logs\kurulum.pid');
  ProgressFile := ExpandConstant('{app}\logs\kurulum-adim.txt');
  DeleteFile(DoneFlag);
  DeleteFile(ProgressFile);

  InstallCancelled := False;
  InstallRunning := True;
  { Betik gizli calisir (SW_HIDE); ciktisi logs\kurulum.log'a yazilir. }
  Started := Exec(PowerShellExe, BuildSetupParams, ExpandConstant('{app}'), SW_HIDE, ewNoWait, SetupExitCode);
  if Started then
  begin
    { Bu bekleme dongusunde Inno'nun Iptal dugmesi calismaz; yerine CustomCancelButton. }
    WizardForm.CancelButton.Visible := False;
    CustomCancelButton.Visible := True;
    CustomCancelButton.Enabled := True;
    ProcessExited := False;
    Ticks := 0;
    repeat
      PumpMessages;
      Sleep(200);
      Ticks := Ticks + 1;
      { Surecin hala calisip calismadigini ~2 sn'de bir denetle (tasklist ucuz degil).
        Bitis bayragi yazilmadan sonlanan bir surecte sihirbaz boylece takilmaz. }
      if (Ticks mod 10 = 0) and (not FileExists(DoneFlag)) and (not InstallCancelled) then
      begin
        if LoadStringFromFile(PidFile, PidAnsi) then SetupPid := Trim(String(PidAnsi)) else SetupPid := '';
        if (SetupPid <> '') and (not ProcessIsRunning(SetupPid)) then ProcessExited := True;
      end;
      { Ilerleme dosyasi her tikte (200 ms) okunur. }
      UpdateInstallProgress(ProgressFile);
    until FileExists(DoneFlag) or InstallCancelled or ProcessExited;
    CustomCancelButton.Visible := False;
    WizardForm.CancelButton.Visible := True;
    { Basariyla bittiyse cubugu tamamla (bkz. UpdateInstallProgress). }
    if FileExists(DoneFlag) and (WizardForm.ProgressGauge.Max > 0) then
      WizardForm.ProgressGauge.Position := WizardForm.ProgressGauge.Max;
  end;
  InstallRunning := False;

  if (not Started) then
  begin
    SummaryPage.RichEditViewer.Lines.Text := 'Kurulum betiği başlatılamadı.';
    Exit;
  end;

  if ProcessExited and not FileExists(DoneFlag) then
    MsgBox('Kurulum betiği beklenmedik şekilde durdu ve bitiş bilgisini yazamadı.' + #13#10#13#10 +
      'Kurulum büyük olasılıkla tamamlanmıştır. Ayrıntı için: ' +
      ExpandConstant('{app}\logs\kurulum.log'), mbError, MB_OK);

  { DoneFlag kosulu kasitli olarak yok: kullanici iptali onayladiysa, betik tam o sirada
    bitmis olsa bile geri alma uygulanir ve sihirbaz kapanir. }
  if InstallCancelled then
  begin
    WizardForm.StatusLabel.Caption := 'İptal ediliyor; o zamana kadar kurulanlar kaldırılıyor…';
    WizardForm.FilenameLabel.Caption := 'Bu birkaç dakika sürebilir.';
    WizardForm.Refresh;
    { PID dosyasini setup-run.ps1 baslarken yazar; /T alt surecleri de (winget, pip,
      hf indirme) sonlandirir. LoadStringFromFile ikinci parametreyi AnsiString bekler. }
    if LoadStringFromFile(PidFile, PidAnsi) then PidText := String(PidAnsi) else PidText := '';
    if Trim(PidText) <> '' then
    begin
      KillParams := '/PID ' + Trim(PidText) + ' /T /F';
      Exec(ExpandConstant('{sys}\taskkill.exe'), KillParams, '', SW_HIDE, ewWaitUntilTerminated, KillResult);
    end;
    { Kaynak kopyasi [Files] adiminda (ssInstall) cikartildigi icin burada her zaman vardir. }
    RollbackScript := ExpandConstant('{app}\kurulum-kaynak\scripts\uninstall-mamidlabs.ps1');
    if FileExists(RollbackScript) then
    begin
      RollbackParams := '-NoProfile -ExecutionPolicy Bypass -File ' + AddQuotes(RollbackScript) +
        ' -Root ' + AddQuotes(ExpandConstant('{app}')) + ' -Yes -FromWizard';
      Exec(PowerShellExe, RollbackParams, GetTempDir, SW_HIDE, ewWaitUntilTerminated, RollbackResult);
    end;
    MsgBox('Kurulum iptal edildi. O zamana kadar kurulanlar kaldırıldı.', mbInformation, MB_OK);
    { Abort burada yetmez (bkz. ExitProcess); sihirbaz dogrudan kapanir. }
    ExitProcess(1);
  end;

  SummaryFile := ExpandConstant('{app}\logs\kurulum-ozeti.txt');
  Text := '';
  if LoadStringsFromFile(SummaryFile, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      Text := Text + Lines[I] + #13#10
  else
    Text := 'Kurulum betiği özet yazamadı. Ayrıntı: ' + ExpandConstant('{app}\logs\kurulum.log');
  SummaryPage.RichEditViewer.Lines.Text := Text;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  App, Script, Params: String;
  KeepUserData: Boolean;
  ResultCode: Integer;
begin
  if CurUninstallStep <> usUninstall then Exit;
  App := ExpandConstant('{app}');
  Script := App + '\scripts\uninstall-mamidlabs.ps1';
  { Varsayilan: hic kurulmamis gibi tam temizlik. Sessiz kaldirmada da tam temizlik yapilir. }
  KeepUserData := False;
  if not UninstallSilent then
    KeepUserData := MsgBox('MamidLabs tamamen kaldırılacak: program, modeller, önbellekler, sohbetler, ' +
      'üretilen dosyalar, ayarlar ve MamidLabs''in kurduğu ön koşullar (Python, Git, 7-Zip, VC++).' + #13#10#13#10 +
      'Sohbetlerini, üretilen görsel/videolarını ve ayarlarını saklamak ister misin?' + #13#10 +
      'Evet: bunlar ' + App + ' altında kalır.   Hayır: her şey silinir.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
  if FileExists(Script) then
  begin
    Params := '-NoProfile -ExecutionPolicy Bypass -File ' + AddQuotes(Script) + ' -Root ' + AddQuotes(App) + ' -Yes -FromWizard';
    if KeepUserData then Params := Params + ' -KeepUserData';
    { Calisma klasoru kurulum koku olmamali; yoksa klasor kilitli kalir. }
    if not Exec(PowerShellExe, Params, GetTempDir, SW_SHOW, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      MsgBox('Bazı dosyalar silinemedi. Açık bir MamidLabs penceresi varsa kapatıp ' + App +
        ' klasörünü elle silebilirsin.', mbInformation, MB_OK);
  end
  else if not KeepUserData then
  begin
    DelTree(App + '\models', True, True, True);
    DelTree(App + '\ComfyUI', True, True, True);
    DelTree(App + '\chats', True, True, True);
    DelTree(App + '\outputs', True, True, True);
    DelTree(App + '\settings', True, True, True);
  end;
end;
