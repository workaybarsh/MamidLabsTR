#Requires -Version 5.1
<#
.SYNOPSIS
    MamidLabs kurulum ve hazirlik betigi.

.DESCRIPTION
    Temiz bir Windows makinesinde MamidLabs'i calisabilir hale getirir: donanim
    on kontrolu, klasor duzeni, gomulu PowerShell 7, llama.cpp CUDA yapisi,
    Python calisma ortamlari ve ComfyUI. Model dosyalari buraya dahil degildir;
    onlar uygulamadaki Profiller menusunden indirilir.

    Her asama tekrar calistirilabilir: var olan bilesen atlanir, -Force ile
    yeniden kurulur. Herhangi bir adim basarisiz olursa betik orada durur ve
    hata dondurur; yarim kurulumu "tamamlandi" diye raporlamaz.

.EXAMPLE
    pwsh -File scripts\install-mamidlabs.ps1 -Profile lite
    8 GB VRAM makinesi icin tam kurulum.

.EXAMPLE
    pwsh -File scripts\install-mamidlabs.ps1 -Stage preflight
    Yalnizca donanim ve ortam kontrolu; hicbir sey indirilmez veya yazilmaz.

.EXAMPLE
    pwsh -File scripts\install-mamidlabs.ps1 -Profile lite -SkipMedia
    Sohbet icin gereken asgari kurulum; ComfyUI ve gorsel/video ortami atlanir.
#>
param(
    # ValidateSet bilerek kullanilmaz: "pwsh -File betik.ps1 -Stage a,b,c" cagrisinda
    # kabuk listeyi tek bir dize olarak gecirir ve dogrulama reddeder. Bolme ve
    # kontrol asagida elle yapilir.
    [string[]]$Stage = @('all'),
    [ValidateSet('max', 'flash', 'lite')][string]$Profile = 'lite',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs'),
    [string]$Source,
    # Betik kaldirma kaydina yazilacak surum (MamidLabs-<hash8>\DisplayVersion). Verilmezse
    # kaynak paketteki packaging\windows\mamidlabs.iss MyAppVersion degeri okunur (surumun
    # tek kaynagi orasidir; bkz. AGENTS.md). MyAppVersion MAJOR.MINOR.PATCH biciminde
    # kalmalidir; baska bicim yok sayilir ve DisplayVersion yazilmaz.
    [string]$AppVersion,
    [switch]$SkipMedia,
    # Ses dökum ortami (venv\asr) medyadan ayridir: -SkipMedia medyayi atlar ama
    # ses yakalamayi atlamaz; yalnizca ses istenmediginde -SkipAudio verilir.
    [switch]$SkipAudio,
    [switch]$Force,
    # Kurulum sihirbazi kendi kaldirma kaydini yazar; betik ikinci bir kayit acmaz.
    [switch]$NoUninstallEntry
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!$Source) { $Source = Split-Path -Parent $PSScriptRoot }
# pip onbellegi (torch tekerlekleri GB'larca) kullanici profiline degil kurulum kokune
# yazilir; uninstall-mamidlabs.ps1 koku sildiginde geride iz kalmaz.
$env:PIP_CACHE_DIR = Join-Path $Root 'tools\pip-cache'

$script:KnownStages = @('all', 'preflight', 'layout', 'runtime', 'llama', 'python', 'asr', 'comfyui', 'verify')
$Stage = @($Stage | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (!$Stage) { $Stage = @('all') }
$unknown = @($Stage | Where-Object { $script:KnownStages -notcontains $_ })
if ($unknown) {
    throw ('Bilinmeyen asama: ' + ($unknown -join ', ') + '. Gecerli degerler: ' + ($script:KnownStages -join ', '))
}

# --------------------------------------------------------------------- surumler
# Boyutlar ilgili GitHub surumunun varlik listesinden alinmistir. Yayinlanmis
# sha256 olmadigi icin butunluk dosya uzunlugu ile dogrulanir; eksik veya yarim
# inen dosya boyut tutmadigi icin yakalanir.
$script:Packages = @{
    pwsh = @{
        url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
        file = 'PowerShell-7.6.6-win-x64.zip'; bytes = 106328873
    }
    llama = @{
        url = 'https://github.com/ggml-org/llama.cpp/releases/download/b10998/llama-b10998-bin-win-cuda-13.4-x64.zip'
        file = 'llama-b10998-bin-win-cuda-13.4-x64.zip'; bytes = 150116398
    }
    cudart = @{
        url = 'https://github.com/ggml-org/llama.cpp/releases/download/b10998/cudart-llama-bin-win-cuda-13.4-x64.zip'
        file = 'cudart-llama-bin-win-cuda-13.4-x64.zip'; bytes = 423535356
    }
}
# Ses dökum modelleri (faster-whisper + AST). Ilk kurulumda HF onbellegine (HF_HOME =
# kok\tools\hf-home) cekilir; calisma aninda aga gerek kalmaz. Whisper: large-v3'un
# Turkce ince ayarli CTranslate2 (float16) surumu.
$script:AsrWhisperModel = 'oguzhangokboru/whisper-large-v3-tr'
$script:AsrEventsModel = 'MIT/ast-finetuned-audioset-10-10-0.4593'
$script:LlamaBuild = 'b10998'
$script:ComfyRepo = 'https://github.com/comfyanonymous/ComfyUI.git'
# Gorsel ve video uretimiyle uctan uca dogrulanmis commit.
$script:ComfyCommit = 'b0f4b7b294ce482a2e071d9d762c133d38c7aa07'
# Lite profilinin Krea-2 Turbo GGUF modelini yuklemesi icin gerekli custom node.
$script:ComfyGgufRepo = 'https://github.com/city96/ComfyUI-GGUF'
$script:ComfyGgufCommit = '6ea2651e7df66d7585f6ffee804b20e92fb38b8a'
# Fotograf duzenleme (Krea 2 Identity Edit) icin gerekli custom node; ek Python bagimliligi yok.
$script:Krea2EditRepo = 'https://github.com/lbouaraba/comfyui-krea2edit'
$script:Krea2EditCommit = '86f886dac23013d88996e3a2e99093ba44d322fb'

# Paket listeleri requirements\ altindaki dosyalardan okunur (tek gercek kaynak;
# agent/*.py iceriklerindeki gercek import'lardan cikarilmistir). Dosya
# bulunamazsa kurulum acik bir hatayla durur; sessizce bos listeyle devam etmez.
function Read-Requirements([string]$name) {
    $path = Join-Path (Join-Path $Source 'requirements') $name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Bagimlilik dosyasi bulunamadi: ' + $path) }
    return @(Get-Content -LiteralPath $path | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ })
}
$script:AppPackages = Read-Requirements 'app.txt'
# imagegen ortami: ComfyUI ve video kare araclari. torch CUDA 13.0 tekerlekleri
# ayri bir dizinden gelir (requirements\imagegen.txt icinde degil); ComfyUI'nin
# kendi requirements'i sonra kurulur.
$script:ImagegenTorch = @('torch', 'torchvision', 'torchaudio')
$script:ImagegenTorchIndex = 'https://download.pytorch.org/whl/cu130'
$script:ImagegenPackages = Read-Requirements 'imagegen.txt'
# Ses (ASR) ortami: faster-whisper (Whisper large-v3-tr) + AST ses olaylari + pyannote.
# torch/torchaudio CUDA 13.0 tekerleklerinden ayri kurulur (imagegen ile ayni index).
$script:AsrTorch = @('torch', 'torchaudio')
$script:AsrPackages = Read-Requirements 'asr.txt'

# Profil basina asgari donanim. Lite'ta Windows masaustunun tuttugu ~1 GB VRAM
# dusuldukten sonra kalan paya gore secilmistir.
$script:Requirements = @{
    lite  = @{ vramMiB = 7000;  ramGB = 14; diskGB = 58 }
    flash = @{ vramMiB = 15000; ramGB = 30; diskGB = 75 }
    max   = @{ vramMiB = 15000; ramGB = 30; diskGB = 75 }
}

# ----------------------------------------------------------------------- ciktilar
$script:Problems = [System.Collections.Generic.List[string]]::new()

function Write-Step([string]$text) { Write-Host ''; Write-Host ('== ' + $text) -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host ('   [ok]   ' + $text) -ForegroundColor Green }
function Write-Skip([string]$text) { Write-Host ('   [atla] ' + $text) -ForegroundColor DarkGray }
function Write-Note([string]$text) { Write-Host ('   [not]  ' + $text) }
function Write-Warn([string]$text) {
    Write-Host ('   [uyari] ' + $text) -ForegroundColor Yellow
    $script:Problems.Add('uyari: ' + $text)
}

function Test-Stage([string]$name) {
    return ($Stage -contains 'all' -or $Stage -contains $name)
}

# Native bir programin stdout+stderr ciktisini metin olarak dondurur.
# Windows PowerShell 5.1'de $ErrorActionPreference 'Stop' iken stderr'i 2>&1 ile
# yonlendirilen program (llama-server --version surumunu stderr'e yazar) betigi
# durduruyordu; bu yuzden cagri boyunca 'Continue' kullanilir. Cikis kodu
# $LASTEXITCODE'da kalir.
function Invoke-NativeText([scriptblock]$command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $command 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim() }
    finally { $ErrorActionPreference = $previous }
}

function Get-FreeSpaceGB([string]$path) {
    $qualifier = (Split-Path -Qualifier ([IO.Path]::GetFullPath($path)))
    $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction Stop
    return [math]::Round($drive.Free / 1GB, 1)
}

# --------------------------------------------------------------------- indirme
function Invoke-Download([string]$url, [string]$destination, [long]$expectedBytes) {
    $name = Split-Path -Leaf $destination
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        ((Get-Item -LiteralPath $destination).Length -eq $expectedBytes)) {
        Write-Skip ($name + ' zaten indirilmis')
        return
    }
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if (!$curl) { throw 'curl.exe bulunamadi; Windows 10 1803 veya uzeri gerekir.' }
    Write-Note ($name + ' indiriliyor (' + [math]::Round($expectedBytes / 1MB) + ' MB)...')
    # -C - yarim kalan indirmeyi surdurur, --fail HTTP hatasinda sifirdan farkli doner.
    & $curl -L --fail --show-error --no-progress-meter --retry 5 --retry-delay 5 -C - -o $destination $url
    if ($LASTEXITCODE -ne 0) { throw ('Indirme basarisiz (' + $name + '), curl cikis kodu ' + $LASTEXITCODE) }
    if (!(Test-Path -LiteralPath $destination -PathType Leaf)) { throw ('Indirilen dosya yok: ' + $name) }
    $actual = (Get-Item -LiteralPath $destination).Length
    if ($actual -ne $expectedBytes) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw ('Boyut tutmadi (' + $name + '): beklenen ' + $expectedBytes + ', gelen ' + $actual + '. Dosya silindi, tekrar calistir.')
    }
    Write-Ok ($name + ' indirildi ve boyutu dogrulandi')
}

function Expand-Package([string]$archive, [string]$destination) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
}

# ------------------------------------------------------------------ on kontrol
function Invoke-Preflight {
    Write-Step ('On kontrol - profil: ' + $Profile)
    $need = $script:Requirements[$Profile]

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Note ($os.Caption + ' (' + $os.Version + ')')
    if ([version]$os.Version -lt [version]'10.0.19041') {
        Write-Warn 'Windows 10 2004 veya uzeri onerilir.'
    }

    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ram -lt $need.ramGB) { Write-Warn ('RAM ' + $ram + ' GB; bu profil icin ' + $need.ramGB + ' GB onerilir.') }
    else { Write-Ok ('RAM ' + $ram + ' GB') }

    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) {
        Write-Warn 'nvidia-smi bulunamadi; NVIDIA surucusu kurulu degil veya PATH disinda. GPU hizlandirma calismayabilir.'
    } else {
        $line = (& $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | Select-Object -First 1)
        $parts = $line -split '\s*,\s*'
        $vram = [int]$parts[1]
        Write-Note ('GPU: ' + $parts[0] + ', ' + $vram + ' MiB VRAM, surucu ' + $parts[2])
        if ($vram -lt $need.vramMiB) {
            Write-Warn ('VRAM ' + $vram + ' MiB; ' + $Profile + ' profili icin ' + $need.vramMiB + ' MiB gerekir. Daha kucuk bir profil sec.')
        } else {
            Write-Ok ('VRAM ' + $vram + ' MiB, ' + $Profile + ' profili icin yeterli')
        }
    }

    $free = Get-FreeSpaceGB $Root
    $modelNote = if ($Profile -eq 'lite') { 'model dosyalari ayrica ~36 GB' } else { 'model dosyalari ayrica ~52 GB' }
    if ($free -lt $need.diskGB) { Write-Warn ($Root + ' diskinde ' + $free + ' GB bos; ' + $need.diskGB + ' GB gerekir (' + $modelNote + ').') }
    else { Write-Ok ([string]$free + ' GB bos disk (' + $modelNote + ')') }

    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (!$python) { Write-Warn 'python PATH uzerinde yok; Python 3.10+ gerekir.' }
    else {
        # Kod stdin ile verilir: Windows PowerShell 5.1 native argumanlardaki cift
        # tirnaklari siler ve "-c" ile verilen Python kodu sozdizimi hatasi verirdi.
        $version = Invoke-NativeText { 'import sys; print(str(sys.version_info[0]) + chr(46) + str(sys.version_info[1]))' | & $python - }
        if ($version -notmatch '^\d+\.\d+$') { Write-Warn ('Python surumu okunamadi: ' + $version) }
        elseif ([version]$version -lt [version]'3.10') { Write-Warn ('Python ' + $version + '; 3.10 veya uzeri gerekir.') }
        else { Write-Ok ('Python ' + $version + ' (' + $python + ')') }
    }

    if (!(Get-Command git -ErrorAction SilentlyContinue)) {
        if ($SkipMedia) { Write-Note 'git yok; -SkipMedia verildigi icin ComfyUI zaten kurulmayacak.' }
        else { Write-Warn 'git bulunamadi; ComfyUI klonlanamaz.' }
    } else { Write-Ok 'git mevcut' }

    # RAR acma (office-tools.py read_rar) icin gerekir; sihirbaz -InstallPrereqs ile
    # winget üzerinden otomatik kurar (bkz. setup-run.ps1 Test-SevenZipReady), burada
    # yalnizca bilgilendirme amacli.
    $sevenZipFound = $false
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ($base -and (Test-Path -LiteralPath (Join-Path $base '7-Zip\7z.exe') -PathType Leaf)) { $sevenZipFound = $true; break }
    }
    if (!$sevenZipFound -and !(Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
        Write-Warn '7-Zip bulunamadi; RAR dosyalarini acma calismayabilir (ZIP/PDF/Office etkilenmez).'
    } else { Write-Ok '7-Zip mevcut (RAR acma calisir)' }

    # llama-server.exe gibi native derlemeler icin gerekir; sihirbaz otomatik kurar.
    $vcRedistFound = [bool]$env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\vcruntime140.dll') -PathType Leaf)
    if (!$vcRedistFound) {
        Write-Warn 'Visual C++ Redistributable (2015-2022, x64) bulunamadi; llama-server calismayabilir.'
    } else { Write-Ok 'Visual C++ Redistributable mevcut' }

    if (!(Test-Path -LiteralPath (Join-Path $Source 'mamidlabs-desktop.ps1') -PathType Leaf)) {
        throw ('Kaynak klasorde mamidlabs-desktop.ps1 yok: ' + $Source)
    }
    Write-Ok ('Kaynak paket: ' + $Source)
}

# ------------------------------------------------------------------- klasorler
# Surumun tek kaynagi packaging\windows\mamidlabs.iss icindeki MyAppVersion'dir. Betik
# tabanli kurulumda da ayni deger kaldirma kaydina yazilir; boylece uygulama ici guncelleme
# denetimi (agent/profile-catalog.ps1 Get-InstalledMamidLabsVersion) betikle kurulmus bir
# kopyanin surumunu okuyabilir. MyAppVersion MAJOR.MINOR.PATCH biciminde kalmalidir.
function Get-SourceAppVersion {
    $iss = Join-Path (Join-Path $Source 'packaging\windows') 'mamidlabs.iss'
    if (!(Test-Path -LiteralPath $iss -PathType Leaf)) { return $null }
    $match = [regex]::Match((Get-Content -LiteralPath $iss -Raw), 'MyAppVersion\s+"(\d+\.\d+\.\d+)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

# Betigin sahip oldugu program klasorleri kopyalamadan once bosaltilir: repodan silinen
# dosyalar guncellemede geride kalmasin (Inno ignoreversion / Copy-Item -Force eski dosyayi
# silmez). Yalnizca program klasorleri; kullanici verisine (settings\, chats\, models\,
# logs\, outputs\, tools\, venv, ComfyUI) DOKUNULMAZ.
function Remove-ProgramDir([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return }
    try {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warn ('Program klasoru temizlenemedi (eski dosyalar kalabilir): ' + $path + ' -> ' + $_.Exception.Message)
    }
}

# Kopyalamadan sonra .iss [Files] ile ayni dislamayi uygular: agent\__pycache__\*, *.pyc.
# Copy-Item -Exclude ozyinelemeli guvenilir olmadigindan kopya sonrasi temizlenir.
# assets\installer (sihirbaz gorselleri) artik DISLANMAZ: kurulu program dosyalari repoyla
# birebir ayni olsun diye oldugu gibi kopyalanir.
function Remove-ProgramExcludes([string]$agentDir) {
    if ($agentDir -and (Test-Path -LiteralPath $agentDir)) {
        Get-ChildItem -LiteralPath $agentDir -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '__pycache__' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $agentDir -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.pyc' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Layout {
    Write-Step 'Klasor duzeni ve program dosyalari'
    $folders = @(
        'agent', 'scripts', 'assets', 'requirements', 'models', 'logs', 'chats', 'settings',
        'llama.cpp', 'ComfyUI', 'venv', 'runtime', 'tools',
        'outputs', 'outputs\images', 'outputs\videolar', 'outputs\belgeler',
        'outputs\refs', 'outputs\thumbs', 'outputs\input'
    )
    foreach ($folder in $folders) {
        New-Item -ItemType Directory -Path (Join-Path $Root $folder) -Force | Out-Null
    }
    Write-Ok ($folders.Count.ToString() + ' klasor hazir')

    # Uygulama aciksa simgeler ve betikler kilitlidir; kopyalama yarida kalir ve kurulum
    # karisik surumde kalir. Once acik bir sey olup olmadigina bakilir.
    $app = Join-Path $Root 'mamidlabs-desktop.ps1'
    $running = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($app, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($running) { throw 'MamidLabs acik; program dosyalari kilitli. Uygulamayi kapatip kurulumu tekrar calistir.' }

    # Betigin sahip oldugu program klasorleri kopyalamadan once temizlenir: repodan silinen
    # dosyalar guncellemede geride kalmasin. Kaynak kokun KENDISI ise (ornegin kurulu kopyadan
    # -Source verilmeden calistirilirsa) kaynagi silmemek ve kendi uzerine kopyalamamak icin
    # atlanir. Kaynagin kokun yalnizca ICINDE olmasi (sihirbazin {kok}\kurulum-kaynak paketi)
    # atlama nedeni DEGILDIR; aksi halde program dosyalari koke hic kopyalanmaz ve taze kurulum
    # bos kalir. Bu yuzden karsilastirma yalnizca ESITLIKtir (ENG'deki $sameRoot gibi).
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $sourceInsideRoot = ($sourceFull -ieq $rootFull)
    if ($sourceInsideRoot) {
        # Kaynak, kurulum kokunun kendisi (kurulu kopyadan -Source verilmeden calistirilir):
        # program dosyalari zaten yerinde; ayni yola kopyalama "kendi uzerine yazilamaz"
        # hatasi verir. Klasorler ve kaldirma kaydi yine tazelenir.
        Write-Skip 'Kaynak kurulum kokunun kendisi; program dosyalari zaten yerinde'
    } else {
        foreach ($folder in @('agent', 'scripts', 'assets', 'requirements')) {
            Remove-ProgramDir (Join-Path $Root $folder)
        }

        # EULA.txt sihirbazin lisans sayfasinda gosterilir ve .iss [Files] ile kaynak pakete
        # gomulur; betik tabanli kurulumda da koke ve kurulum-kaynak'e kopyalanmali.
        foreach ($file in @('mamidlabs-desktop.ps1', 'launch-mamidlabs-desktop.vbs', 'README.md', 'LICENSE', 'EULA.txt')) {
            $from = Join-Path $Source $file
            if (Test-Path -LiteralPath $from -PathType Leaf) {
                Copy-Item -LiteralPath $from -Destination (Join-Path $Root $file) -Force
            }
        }
        foreach ($folder in @('agent', 'scripts', 'assets')) {
            $from = Join-Path $Source $folder
            if (Test-Path -LiteralPath $from) {
                Copy-Item -LiteralPath $from -Destination $Root -Recurse -Force
            }
        }
        # requirements kokte de bulunmali: AGENTS.md'deki belgelenen guncelleme komutu
        # (install-mamidlabs.ps1 -Stage layout, -Source verilmeden) bagimliliklari kokten okur.
        $requirements = Join-Path $Source 'requirements'
        if (Test-Path -LiteralPath $requirements) {
            Copy-Item -LiteralPath $requirements -Destination $Root -Recurse -Force
        }
        # .iss [Files] ile ayni dislama: agent onbellekleri koke girmez. assets\installer da
        # (repoyla birebir aynilik icin) koke kopyalanir.
        Remove-ProgramExcludes (Join-Path $Root 'agent')
        Write-Ok ('Program dosyalari kopyalandi -> ' + $Root)
    }

    # Sihirbazla kurulmus bir kok, program kaynagini {kok}\kurulum-kaynak altinda da tutar;
    # Inno iptal/geri alma ve yeniden kurulum bunu kullanir. Betik tabanli guncelleme
    # (bu asama) bu klasoru tazelemedigi icin onceki surumden kaliyordu; varsa ayni [Files]
    # kumesiyle tazelenir. Betikle yapilan kurulumda (klasor yoksa) bosuna olusturulmaz.
    $kaynak = Join-Path $Root 'kurulum-kaynak'
    if (Test-Path -LiteralPath $kaynak -PathType Container) {
        # Kaynak paketin KENDISI zaten kaynaksa (sihirbaz: -Source {kok}\kurulum-kaynak) tazeleme
        # anlamsizdir; ust dosyalari/klasorleri kendi uzerine kopyalamak "kendi uzerine
        # yazilamaz" hatasi verir ve paketi bosaltip bozardi. Bu durumda tazeleme atlanir.
        $kaynakFull = [IO.Path]::GetFullPath($kaynak).TrimEnd('\')
        if ($sourceFull -ine $kaynakFull) {
            # Repodan silinen dosyalar kaynak pakette de kalmasin diye tazelenen klasorler once
            # bosaltilir (program klasorleri; kullanici verisi bu pakette tutulmaz).
            foreach ($folder in @('agent', 'scripts', 'requirements', 'assets')) {
                Remove-ProgramDir (Join-Path $kaynak $folder)
            }
            # Ayni ust dosya listesi (EULA.txt dahil) kaynak pakete de yazilir.
            foreach ($file in @('mamidlabs-desktop.ps1', 'launch-mamidlabs-desktop.vbs', 'README.md', 'LICENSE', 'EULA.txt')) {
                $from = Join-Path $Source $file
                if (Test-Path -LiteralPath $from -PathType Leaf) { Copy-Item -LiteralPath $from -Destination $kaynak -Force }
            }
            foreach ($folder in @('agent', 'scripts', 'requirements')) {
                $from = Join-Path $Source $folder
                if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $kaynak -Recurse -Force }
            }
            $assets = Join-Path $Source 'assets'
            if (Test-Path -LiteralPath $assets) {
                # assets\installer (sihirbaz gorselleri) de dahil tum assets kopyalanir; kurulu
                # program dosyalari repoyla birebir ayni kalsin.
                New-Item -ItemType Directory -Path (Join-Path $kaynak 'assets') -Force | Out-Null
                Get-ChildItem -LiteralPath $assets -Force | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $kaynak 'assets') -Recurse -Force
                }
            }
            # .iss ile ayni dislama (agent onbellekleri) kaynak pakette de uygulanir.
            Remove-ProgramExcludes (Join-Path $kaynak 'agent')
            $doc = Join-Path $Source 'docs\kurulum.md'
            if (Test-Path -LiteralPath $doc -PathType Leaf) {
                New-Item -ItemType Directory -Path (Join-Path $kaynak 'docs') -Force | Out-Null
                Copy-Item -LiteralPath $doc -Destination (Join-Path $kaynak 'docs\kurulum.md') -Force
            }
            Write-Ok ('Kurulum kaynak paketi tazelendi -> ' + $kaynak)
        }
    }

    # Masaustu kisayolu: cift tikla ac, konsol penceresi acmadan calisir. MamidLabs.lnk
    # baska bir klasordeki kuruluma isaret ediyorsa ona dokunulmaz; bu kurulum icin
    # "MamidLabs (<klasor>).lnk" acilir. Kaldirici yalnizca bu koke isaret edenleri siler.
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shell = New-Object -ComObject WScript.Shell
        $linkPath = Join-Path $desktop 'MamidLabs.lnk'
        if (Test-Path -LiteralPath $linkPath) {
            $existing = $shell.CreateShortcut($linkPath)
            $pointsHere = (($existing.TargetPath + ' ' + $existing.Arguments + ' ' + $existing.WorkingDirectory).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            if (!$pointsHere) { $linkPath = Join-Path $desktop ('MamidLabs (' + (Split-Path -Leaf $Root) + ').lnk') }
        }
        $target = Join-Path $Root 'launch-mamidlabs-desktop.vbs'
        $icon = Join-Path $Root 'assets\icons\mamidlabs.ico'
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (!(Test-Path -LiteralPath $linkPath) -or $Force)) {
            $shortcut = $shell.CreateShortcut($linkPath)
            $shortcut.TargetPath = $target
            $shortcut.WorkingDirectory = $Root
            if (Test-Path -LiteralPath $icon -PathType Leaf) { $shortcut.IconLocation = $icon }
            $shortcut.Description = 'MamidLabs - yerel asistan'
            $shortcut.Save()
            Write-Ok ('Masaustu kisayolu olusturuldu -> ' + $linkPath)
        } elseif (Test-Path -LiteralPath $linkPath) {
            Write-Skip 'Masaustu kisayolu zaten var'
        }
    } catch {
        Write-Warn ('Masaustu kisayolu olusturulamadi: ' + $_.Exception.Message)
    }

    # Ayarlar > Uygulamalar listesinde gorunur; "Kaldir" uninstall-mamidlabs.ps1'i calistirir.
    if ($NoUninstallEntry) { return }
    try {
        $version = if ($AppVersion) { $AppVersion } else { Get-SourceAppVersion }
        $uninstallBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        # Sihirbaz (Inno) bu kok icin zaten {AppId}_is1 kaydini yazdiysa ikinci bir betik
        # kaydi acma; aksi halde Ayarlar > Uygulamalar'da mukerrer MamidLabs girdisi gorunur.
        $wizardOwnsThisRoot = $false
        foreach ($item in @(Get-ChildItem -LiteralPath $uninstallBase -ErrorAction SilentlyContinue)) {
            if ($item.PSChildName -notlike '*_is1') { continue }
            $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (!$props -or ![string]$props.InstallLocation) { continue }
            try { $location = [IO.Path]::GetFullPath([string]$props.InstallLocation).TrimEnd('\') } catch { continue }
            if ($location -ieq $rootFull) { $wizardOwnsThisRoot = $true; break }
        }
        if ($wizardOwnsThisRoot) {
            Write-Skip 'Windows kaldirma kaydi sihirbaz tarafindan zaten yazilmis'
        } else {
            $key = Join-Path $uninstallBase (Get-UninstallKeyName $Root)
            $uninstaller = Join-Path $Root 'scripts\uninstall-mamidlabs.ps1'
            $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '" -Root "' + $Root + '"'
            New-Item -Path $key -Force | Out-Null
            $values = @{
                DisplayName = 'MamidLabs (' + $Root + ')'
                Publisher = 'workaybarsh'; InstallLocation = $Root; UninstallString = $command
                DisplayIcon = (Join-Path $Root 'assets\icons\mamidlabs.ico'); URLInfoAbout = 'https://github.com/workaybarsh/MamidLabsTR'
            }
            # Uygulama ici guncelleme denetimi bu surumu {AppId}_is1 yoksa buradan okur.
            if ($version) { $values['DisplayVersion'] = $version }
            foreach ($name in $values.Keys) { Set-ItemProperty -Path $key -Name $name -Value $values[$name] }
            foreach ($name in @('NoModify', 'NoRepair')) { Set-ItemProperty -Path $key -Name $name -Value 1 -Type DWord }
            Write-Ok 'Windows kaldirma kaydi yazildi (Ayarlar > Uygulamalar > MamidLabs)'
        }
    } catch {
        Write-Warn ('Kaldirma kaydi yazilamadi: ' + $_.Exception.Message)
    }
}

# Kok basina ayri kayit: iki farkli klasore kurulan kopyalar birbirinin kaydini ezmez.
# uninstall-mamidlabs.ps1 ayni adi ayni yontemle uretir.
function Get-UninstallKeyName([string]$path) {
    $normalized = [IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)) } finally { $sha.Dispose() }
    return 'MamidLabs-' + (($hash[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# --------------------------------------------------------- gomulu PowerShell 7
function Invoke-Runtime {
    Write-Step 'Gomulu PowerShell 7 calisma zamani'
    $target = Join-Path $Root 'runtime\pwsh'
    $exe = Join-Path $target 'pwsh.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -and !$Force) {
        Write-Skip 'runtime\pwsh zaten kurulu'
        return
    }
    # Uygulama Start-ThreadJob'a muhtac; bu yalnizca PowerShell 7'de var. Sisteme
    # kurulu pwsh Store paketi olabilecegi icin (WindowsApps kilitli) tasinabilir
    # surum ayrica acilir.
    $cache = Join-Path $Root 'tools\indirme'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $archive = Join-Path $cache $script:Packages.pwsh.file
    Invoke-Download $script:Packages.pwsh.url $archive $script:Packages.pwsh.bytes
    Expand-Package $archive $target
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'pwsh.exe acilan arsivde bulunamadi.' }
    $reported = (& $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
    Write-Ok ('runtime\pwsh hazir, surum ' + $reported)
}

# ----------------------------------------------------------------- llama.cpp
function Invoke-Llama {
    Write-Step ('llama.cpp CUDA yapisi (' + $script:LlamaBuild + ')')
    $target = Join-Path $Root ('llama.cpp\' + $script:LlamaBuild)
    $exe = Join-Path $target 'llama-server.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -and !$Force) {
        Write-Skip 'llama-server.exe zaten kurulu'
        return
    }
    $cache = Join-Path $Root 'tools\indirme'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    foreach ($key in @('llama', 'cudart')) {
        $package = $script:Packages[$key]
        $archive = Join-Path $cache $package.file
        Invoke-Download $package.url $archive $package.bytes
        # Ikisi de ayni klasore acilir: llama-server.exe CUDA DLL'lerini yaninda arar.
        Expand-Package $archive $target
    }
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'llama-server.exe acilan arsivde bulunamadi.' }
    Write-Ok 'llama.cpp ve CUDA calisma zamani acildi'
}

# ------------------------------------------------------------------ ses (ASR)
# Konusma dökumu: faster-whisper (Whisper large-v3-tr) + AST ses olaylari. Modeller ilk
# kurulumda HF onbellegine (HF_HOME = kok\tools\hf-home) cekilir; calisma aninda ag
# gerekmez. venv\asr "python" asamasinda olusturulur (bkz. Invoke-Python).
function Invoke-Asr {
    Write-Step 'Ses dökum modelleri (Whisper large-v3-tr + AST)'
    if ($SkipAudio) { Write-Skip 'Ses dökum modelleri (-SkipAudio)'; return }
    $python = Join-Path $Root 'venv\asr\Scripts\python.exe'
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) {
        Write-Warn 'venv\asr bulunamadi; once "python" asamasi calistirilmali.'
        return
    }
    $env:HF_HOME = Join-Path $Root 'tools\hf-home'
    $env:HF_HUB_DISABLE_TELEMETRY = '1'
    $env:MAMIDLABS_ASR_WHISPER = $script:AsrWhisperModel
    $env:MAMIDLABS_ASR_EVENTS = $script:AsrEventsModel
    $code = @'
import os
from huggingface_hub import snapshot_download
for repo in (os.environ["MAMIDLABS_ASR_WHISPER"], os.environ["MAMIDLABS_ASR_EVENTS"]):
    print("indiriliyor: " + repo, flush=True)
    snapshot_download(repo_id=repo)
    print("tamam: " + repo, flush=True)
'@
    try {
        $output = Invoke-NativeText { $code | & $python - }
        if ($output -match 'tamam:') { Write-Ok 'Ses dökum modelleri hazir (HF onbellegi)' }
        else { Write-Warn ('Ses modelleri dogrulanamadi: ' + $output) }
    } catch {
        Write-Warn ('Ses modelleri indirilemedi: ' + $_.Exception.Message)
    }
}

# ------------------------------------------------------------- Python ortamlari
function New-Venv([string]$path, [string]$label) {
    $python = Join-Path $path 'Scripts\python.exe'
    if ((Test-Path -LiteralPath $python -PathType Leaf) -and !$Force) {
        Write-Skip ($label + ' ortami zaten var')
        return $python
    }
    $base = (Get-Command python -ErrorAction Stop).Source
    Write-Note ($label + ' ortami olusturuluyor...')
    & $base -m venv $path
    if ($LASTEXITCODE -ne 0) { throw ($label + ' icin venv olusturulamadi.') }
    & $python -m pip install --upgrade pip --quiet --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw ($label + ' icin pip guncellenemedi.') }
    return $python
}

function Install-Packages([string]$python, [string[]]$packages, [string]$label, [string]$index) {
    Write-Note ($label + ': ' + ($packages -join ', '))
    $arguments = @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check') + $packages
    if ($index) { $arguments += @('--index-url', $index) }
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { throw ($label + ' paketleri kurulamadi.') }
    Write-Ok ($label + ' paketleri kuruldu')
}

function Invoke-Python {
    Write-Step 'Python calisma ortamlari'
    $appPython = New-Venv (Join-Path $Root 'venv\app') 'uygulama'
    Install-Packages $appPython $script:AppPackages 'uygulama' $null

    # Ses (ASR) ortami medyadan bagimsizdir: yalnizca ses istenmediginde atlanir.
    if (!$SkipAudio) {
        $asrPython = New-Venv (Join-Path $Root 'venv\asr') 'ses (ASR)'
        Install-Packages $asrPython $script:AsrTorch 'ses torch (CUDA 13.0)' $script:ImagegenTorchIndex
        Install-Packages $asrPython $script:AsrPackages 'ses (ASR)' $null
    } else {
        Write-Skip 'ses (ASR) ortami (ses istenmedi)'
    }

    if ($SkipMedia -and $SkipAudio) {
        Write-Skip 'imagegen ortami (medya ve ses de istenmedi)'
        return
    }
    $imagegen = New-Venv (Join-Path $Root 'venv\imagegen') 'imagegen'
    Install-Packages $imagegen $script:ImagegenTorch 'imagegen torch (CUDA 13.0)' $script:ImagegenTorchIndex
    Install-Packages $imagegen $script:ImagegenPackages 'imagegen medya' $null

    Write-Note 'OCR ortamlari bu betige dahil degil: scripts\install-ocr.ps1 -Warmup'
}

# --------------------------------------------------------------------- ComfyUI
# Var olan bir git kopyasini sabit commit'e getirir. Onceden klasor varsa hic
# bakilmadan atlaniyordu; eski bir ComfyUI (gercek makinede 7a0b5ee, 6 gun eski)
# sabit surume hic gecmiyordu. Yerel degisiklikler silinmeden once yedeklenir.
function Sync-PinnedCheckout([string]$dir, [string]$repoUrl, [string]$commit, [string]$label) {
    # git uyarilarini stderr'e yazar (ornegin satir sonu uyarisi); 5.1'de 'Stop' ile
    # bunlar betigi durdururdu. Gercek hatalar asagida cikis koduyla yakalanir.
    $ErrorActionPreference = 'Continue'
    if (!(Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        Write-Warn ($label + ' bir git kopyasi degil; surumu dogrulanamiyor. Sabit surum icin -Force ile yeniden kur.')
        return
    }
    $head = (& git -C $dir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($head -eq $commit) {
        Write-Skip ($label + ' zaten sabit surumde (' + $commit.Substring(0, 12) + ')')
        return
    }
    $headText = if ($head) { $head.Substring(0, [Math]::Min(12, $head.Length)) } else { 'bilinmiyor' }
    Write-Note ($label + ' ' + $headText + ' surumunde; sabit ' + $commit.Substring(0, 12) + ' surumune geciliyor...')
    $diff = (& git -C $dir diff 2>$null | Out-String)
    if ($diff.Trim()) {
        $backupDir = Join-Path $Root 'tools\yedek'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backup = Join-Path $backupDir ('{0}-{1}-{2:yyyyMMdd-HHmmss}.patch' -f ($label -replace '\W', '').ToLowerInvariant(), $headText, (Get-Date))
        [IO.File]::WriteAllText($backup, $diff, [Text.UTF8Encoding]::new($false))
        Write-Note ('Yerel degisiklikler yedeklendi: ' + $backup)
    }
    if (!(& git -C $dir remote 2>$null | Where-Object { $_ -eq 'origin' })) { & git -C $dir remote add origin $repoUrl }
    & git -C $dir fetch --depth 1 origin $commit
    if ($LASTEXITCODE -ne 0) { throw ($label + ' getirilemedi (commit: ' + $commit + ').') }
    & git -C $dir checkout -q --force FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw ($label + ' sabit surume gecirilemedi.') }
    Write-Ok ($label + ' sabit surume getirildi (' + $commit.Substring(0, 12) + ')')
}

# Bir ComfyUI custom node'unu sabit commit'e kurar ya da var olan kopyayi o commit'e getirir.
function Install-PinnedCustomNode([string]$comfyDir, [string]$name, [string]$repoUrl, [string]$commit) {
    $node = Join-Path $comfyDir ('custom_nodes\' + $name)
    if ((Test-Path -LiteralPath (Join-Path $node '__init__.py') -PathType Leaf) -and !$Force) {
        Sync-PinnedCheckout $node $repoUrl $commit $name
        return
    }
    if (Test-Path -LiteralPath $node -PathType Container) { Remove-Item -LiteralPath $node -Recurse -Force }
    New-Item -ItemType Directory -Path $node -Force | Out-Null
    & git -C $node init -q
    & git -C $node remote add origin $repoUrl
    & git -C $node fetch --depth 1 origin $commit
    if ($LASTEXITCODE -ne 0) { throw ($name + ' getirilemedi (commit: ' + $commit + ').') }
    & git -C $node checkout -q FETCH_HEAD
    if (!(Test-Path -LiteralPath (Join-Path $node '__init__.py') -PathType Leaf)) { throw ($name + ' __init__.py bulunamadi.') }
    Write-Ok ($name + ' klonlandi (commit ' + $commit.Substring(0, 12) + ')')
}

function Invoke-ComfyUI {
    Write-Step 'ComfyUI'
    if ($SkipMedia) { Write-Skip 'ComfyUI (-SkipMedia)'; return }
    $target = Join-Path $Root 'ComfyUI'
    $main = Join-Path $target 'main.py'
    # Calisan bir ComfyUI (onceki oturumdan/acik uygulamadan) dosyalari kilitler ve git
    # islemleri takilir; asama basinda bu koke ait surec durdurulur.
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -like '*ComfyUI\main.py*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Note ('Durduruldu: ComfyUI (' + $_.ProcessId + ')') } catch { } }
    if ((Test-Path -LiteralPath $main -PathType Leaf) -and !$Force) {
        Sync-PinnedCheckout $target $script:ComfyRepo $script:ComfyCommit 'ComfyUI'
    } else {
        if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'git bulunamadi; ComfyUI klonlanamaz.' }
        # Klasor layout asamasinda olusturuldugu icin bos dizine klonlanir. Sabit bir
        # commit'e kilitlenir: "git clone --depth 1" varsayilan dala
        # (main) baglidir, farkli tarihlerde kurulum yapan iki kullanici farkli
        # ComfyUI surumu alip is akislari (workflow JSON, node API) sessizce
        # bozulabilirdi. GitHub rastgele bir commit SHA'sini shallow fetch etmeyi
        # destekledigi icin depth 1 korunuyor.
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        & git -C $target init -q
        if ($LASTEXITCODE -ne 0) { throw 'ComfyUI klasoru hazirlanamadi.' }
        & git -C $target remote add origin $script:ComfyRepo
        & git -C $target fetch --depth 1 origin $script:ComfyCommit
        if ($LASTEXITCODE -ne 0) { throw 'ComfyUI getirilemedi (commit: ' + $script:ComfyCommit + ').' }
        & git -C $target checkout -q FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { throw 'ComfyUI checkout basarisiz.' }
        if (!(Test-Path -LiteralPath $main -PathType Leaf)) { throw 'ComfyUI main.py bulunamadi.' }
        Write-Ok ('ComfyUI klonlandi (commit ' + $script:ComfyCommit.Substring(0, 12) + ')')
    }
    $python = Join-Path $Root 'venv\imagegen\Scripts\python.exe'
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw 'imagegen ortami yok; once -Stage python calistir.' }
    Write-Note 'ComfyUI requirements kuruluyor (torch zaten kurulu, tekrar indirilmez)...'
    & $python -m pip install --quiet --disable-pip-version-check -r (Join-Path $target 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'ComfyUI requirements kurulamadi.' }
    Write-Ok 'ComfyUI bagimliliklari kuruldu'

    # Lite profili Krea-2 Turbo'nun GGUF kuantize surumunu (8 GB VRAM'e sigar)
    # kullanir; ComfyUI bunu yerlesik desteklemez, city96/ComfyUI-GGUF gerekir.
    Install-PinnedCustomNode $target 'ComfyUI-GGUF' $script:ComfyGgufRepo $script:ComfyGgufCommit
    # Fotograf duzenleme: Krea2EditModelPatch ve Krea2EditGroundedEncode dugumleri.
    Install-PinnedCustomNode $target 'comfyui-krea2edit' $script:Krea2EditRepo $script:Krea2EditCommit
    & $python -m pip install --quiet --disable-pip-version-check gguf
    if ($LASTEXITCODE -ne 0) { throw 'gguf paketi kurulamadi.' }
    Write-Ok 'ComfyUI-GGUF bagimliligi (gguf paketi) kuruldu'

    foreach ($folder in @('models\checkpoints', 'models\diffusion_models', 'models\unet', 'models\text_encoders', 'models\vae', 'models\loras')) {
        New-Item -ItemType Directory -Path (Join-Path $target $folder) -Force | Out-Null
    }
    Write-Ok 'ComfyUI model klasorleri hazir'
}

# -------------------------------------------------------------------- dogrulama
function Invoke-Verify {
    Write-Step 'Kurulum dogrulamasi'
    $checks = @(
        @{ label = 'Uygulama';            path = 'mamidlabs-desktop.ps1' },
        @{ label = 'Profil katalogu';     path = 'agent\profiles.json' },
        @{ label = 'Profil modulu';       path = 'agent\profile-catalog.ps1' },
        @{ label = 'Model yoneticisi';    path = 'scripts\manage-mamidlabs.ps1' },
        @{ label = 'Gomulu PowerShell 7'; path = 'runtime\pwsh\pwsh.exe' },
        @{ label = 'llama-server';        path = ('llama.cpp\' + $script:LlamaBuild + '\llama-server.exe') },
        @{ label = 'uygulama ortami';    path = 'venv\app\Scripts\python.exe' }
    )
    if (!$SkipMedia -or !$SkipAudio) {
        $checks += @{ label = 'imagegen ortami'; path = 'venv\imagegen\Scripts\python.exe' }
    }
    if (!$SkipMedia) {
        $checks += @{ label = 'ComfyUI';         path = 'ComfyUI\main.py' }
        $checks += @{ label = 'ComfyUI-GGUF';    path = 'ComfyUI\custom_nodes\ComfyUI-GGUF\__init__.py' }
        $checks += @{ label = 'Fotograf duzenleme dugumleri'; path = 'ComfyUI\custom_nodes\comfyui-krea2edit\__init__.py' }
    }
    if (!$SkipAudio) {
        $checks += @{ label = 'ses (ASR) ortami'; path = 'venv\asr\Scripts\python.exe' }
        $checks += @{ label = 'whisper-tools.py'; path = 'agent\whisper-tools.py' }
    }
    foreach ($check in $checks) {
        # Zip icindeki yuva (ornegin 'Release\') surume gore degisebilir; glob varsa
        # dosyayi klasor altinda ozyinelemeli ara.
        if ($check.glob) {
            $hit = @(Get-ChildItem -LiteralPath (Join-Path $Root $check.path) -Recurse -Filter $check.glob -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($hit.Count) { Write-Ok $check.label } else { Write-Warn ($check.label + ' eksik: ' + $check.path + '\' + $check.glob) }
            continue
        }
        $full = Join-Path $Root $check.path
        if (Test-Path -LiteralPath $full -PathType Leaf) { Write-Ok ($check.label + ' -> ' + $check.path) }
        else { Write-Warn ($check.label + ' eksik: ' + $check.path) }
    }

    $server = Join-Path $Root ('llama.cpp\' + $script:LlamaBuild + '\llama-server.exe')
    if (Test-Path -LiteralPath $server -PathType Leaf) {
        # --version GPU ayirmadan calisir; CUDA DLL'leri eksikse burada anlasilir.
        $output = Invoke-NativeText { & $server --version }
        if ($LASTEXITCODE -eq 0 -or $output) { Write-Ok ('llama-server yanit verdi: ' + ($output -split "`n")[0]) }
        else { Write-Warn 'llama-server calistirilamadi; CUDA calisma zamani eksik olabilir.' }
    }

    $appPython = Join-Path $Root 'venv\app\Scripts\python.exe'
    if (Test-Path -LiteralPath $appPython -PathType Leaf) {
        $modules = 'huggingface_hub,requests,PIL,ddgs,pypdf,reportlab,docx,pptx,openpyxl,rarfile'
        $script = 'import importlib.util' + "`n" +
                  'missing=[m for m in "' + $modules + '".split(",") if not importlib.util.find_spec(m)]' + "`n" +
                  'print("EKSIK:"+",".join(missing) if missing else "TAMAM")'
        # Kod cift tirnak icerdigi icin stdin ile verilir (5.1 argumandaki tirnaklari siler).
        $result = Invoke-NativeText { $script | & $appPython - }
        if ($result -eq 'TAMAM') { Write-Ok 'uygulama paketleri iceri aktarilabiliyor' }
        else { Write-Warn ('uygulama ortaminda eksik paket -> ' + $result) }
    }

    Write-Step 'Ozet'
    if ($script:Problems.Count) {
        Write-Host ('   ' + $script:Problems.Count + ' sorun var:') -ForegroundColor Yellow
        foreach ($problem in $script:Problems) { Write-Host ('     - ' + $problem) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '   Model dosyalari bu betige dahil degildir.' -ForegroundColor DarkGray
    } else {
        Write-Host '   Kurulum tamam. Siradaki adimlar:' -ForegroundColor Green
        Write-Host ''
        Write-Host ('   1. Uygulamayi ac:  ' + (Join-Path $Root 'launch-mamidlabs-desktop.vbs'))
        Write-Host '   2. Sol ustteki Profiller menusunden profili sec.'
        Write-Host '   3. Eksik model dosyalarini "Profil yoneticisi -> Eksikleri indir" ile cek.'
        if ($Profile -eq 'lite') {
            Write-Host '      LITE icin toplam ~36 GB iner (9B dil modeli, Krea-2 Turbo GGUF + destek dosyalari, Wan 2.2).'
        } else {
            Write-Host '      MAX/FLASH icin toplam ~52 GB iner (27B dil modeli, Krea-2 Turbo fp8 + destek dosyalari, Wan 2.2).'
        }
        Write-Host '   4. OCR istiyorsan:  pwsh -File scripts\install-ocr.ps1 -Warmup'
    }
}

# ------------------------------------------------------------------------ akis
$stages = [ordered]@{
    preflight = { Invoke-Preflight }
    layout    = { Invoke-Layout }
    runtime   = { Invoke-Runtime }
    llama     = { Invoke-Llama }
    python    = { Invoke-Python }
    asr       = { Invoke-Asr }
    comfyui   = { Invoke-ComfyUI }
    verify    = { Invoke-Verify }
}

Write-Host ''
Write-Host 'MamidLabs kurulum' -ForegroundColor White
Write-Host ('  hedef : ' + $Root)
Write-Host ('  profil: ' + $Profile)
Write-Host ('  asama : ' + ($Stage -join ', '))

foreach ($name in $stages.Keys) {
    if (Test-Stage $name) { & $stages[$name] }
}
Write-Host ''
