#Requires -Version 5.1
<#
.SYNOPSIS
    MamidLabs'i geride iz birakmadan kaldirir.

.DESCRIPTION
    Kurulumun makinede biraktigi her seyi siler; bilgisayar MamidLabs hic
    kurulmamis gibi kalir:

      1. Kurulum kokunden calisan surecler durdurulur (uygulama, llama-server, ComfyUI).
      2. Kurulum koku: program, gomulu PowerShell, llama.cpp, Python ortamlari,
         ComfyUI, modeller, pip/Hugging Face/OCR onbellekleri, loglar, sohbetler,
         ciktilar ve ayarlar (sifreli API anahtarlari dahil).
      3. Bu kuruluma isaret eden masaustu kisayolu.
      4. Windows kaldirma kaydi (Ayarlar > Uygulamalar > MamidLabs).
      5. Kurulum sihirbazinin winget ile kurdugu on kosullar (Python, Git, 7-Zip,
         VC++ Redistributable; yalnizca MamidLabs kurduysa, settings\kurulum-kaydi.json).
         Onceden kurulu olanlara dokunulmaz.

    Kurulum kokunun disindaki dosyalara dokunulmaz: dosya yoluyla secilen kendi
    modellerin yerinde kalir. Kokte MamidLabs'e ait olmayan dosya varsa once sorulur.

    Betik Windows PowerShell 5.1 ile calisir; gomulu PowerShell 7 de silinecegi icin
    onu kullanmaz. Metinler bu yuzden ASCII'dir.

    Betik kurulumun kendi scripts\ klasorunden calistirilir; -Root verilmezse kok
    oradan bulunur.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\uninstall-mamidlabs.ps1 -DryRun
    Neyin silinecegini listeler, hicbir sey silmez.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\uninstall-mamidlabs.ps1
    Plani gosterir, onay ister ve her seyi siler.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\uninstall-mamidlabs.ps1 -KeepUserData
    Sohbetler, uretilen dosyalar ve ayarlar kalir; geri kalan her sey silinir.
#>
param(
    [string]$Root,
    # chats, outputs ve settings klasorlerini saklar.
    [switch]$KeepUserData,
    # MamidLabs'in winget ile kurdugu on kosullari (Python, Git, 7-Zip, VC++) kaldirmaz.
    [switch]$KeepPrerequisites,
    # Kurulum klasoru disindaki paylasilan Python onbelleklerini de siler:
    # %LOCALAPPDATA%\pip\cache, ~\.cache\huggingface\xet, %TEMP%\torchinductor_<kullanici>.
    # Bunlari baska Python projeleri de kullanabilir; yalnizca istenirse silinir.
    [switch]$PurgeSharedCaches,
    # Onay sormadan calisir (sihirbazin kaldiricisi kullanir).
    [switch]$Yes,
    # Yalnizca plani gosterir, hicbir sey silmez.
    [switch]$DryRun,
    # Inno Setup kaldiricisindan cagrildi: kendi kaydini ve unins000.* dosyalarini o siler.
    [switch]$FromWizard,
    # Testler icin: gercek masaustu ve kayit defteri yerine baska konum.
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
    [string[]]$UninstallRegistryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Kurulum koku silinirken betigin calisma klasoru orada kalmamali (klasor kilitlenir).
Set-Location -LiteralPath $env:TEMP
[Environment]::CurrentDirectory = $env:TEMP

function Write-Line([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

if (!$Root) {
    # Betik kurulumun icinden (scripts\) calisiyorsa kok onun ust klasorudur.
    $parent = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { '' }
    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent 'agent\profiles.json'))) { $Root = $parent }
    else { $Root = Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs' }
}
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')

# ------------------------------------------------------------------ guvenlik
function Test-ProtectedPath([string]$path) {
    $p = $path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $true }
    $protected = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads')) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    return [bool]($protected | Where-Object { $_ -ieq $p })
}

if (!(Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Line "Kurulum klasoru bulunamadi: $Root" 'Yellow'
    exit 1
}
if (Test-ProtectedPath $Root) {
    Write-Line "Guvenlik: $Root bir sistem ya da kullanici klasoru; kaldirma yapilmadi." 'Red'
    exit 1
}
$markers = @('agent\profiles.json', 'qwen-desktop.ps1', 'launch-qwen-desktop.vbs')
if (!($markers | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) })) {
    Write-Line "Guvenlik: $Root bir MamidLabs kurulumu gibi gorunmuyor (qwen-desktop.ps1 / agent\profiles.json yok); kaldirma yapilmadi." 'Red'
    exit 1
}

# -------------------------------------------------------------------- plan
# Kurulumun kokte olusturdugu her sey. Burada olmayan girisler kullaniciya sorulur.
$programEntries = @('agent', 'scripts', 'assets', 'requirements', 'models', 'logs', 'llama.cpp', 'ComfyUI', 'venv',
    'runtime', 'tools', 'kurulum-kaynak', 'qwen-desktop.ps1', 'launch-qwen-desktop.vbs',
    'README.md', 'LICENSE', 'EULA.txt')
$userEntries = @('chats', 'outputs', 'settings')
$wizardEntries = @('unins000.exe', 'unins000.dat', 'unins000.msg')

$existing = @(Get-ChildItem -LiteralPath $Root -Force | ForEach-Object { $_.Name })
$toDelete = @($existing | Where-Object { $programEntries -contains $_ })
if (!$KeepUserData) { $toDelete += @($existing | Where-Object { $userEntries -contains $_ }) }
if (!$FromWizard) { $toDelete += @($existing | Where-Object { $wizardEntries -contains $_ }) }
$known = $programEntries + $userEntries + $wizardEntries
$foreign = @($existing | Where-Object { $known -notcontains $_ })

# Kurulum kaydi silinmeden once okunur.
$wingetPackages = @()
$recordPath = Join-Path $Root 'settings\kurulum-kaydi.json'
if (!$KeepPrerequisites -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
    try { $wingetPackages = @((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).wingetPackages | Where-Object { $_ }) } catch { }
}

# Kokten calisan surecler. Bu betik ve onu baslatan zincir (sihirbaz kaldiricisi da
# komut satirinda kok yolunu tasir) haric tutulur.
function Get-AncestorIds {
    $ids = @($PID)
    $all = @(Get-CimInstance Win32_Process)
    $current = $all | Where-Object { $_.ProcessId -eq $PID }
    while ($current -and $current.ParentProcessId -and $ids -notcontains [int]$current.ParentProcessId) {
        $ids += [int]$current.ParentProcessId
        $current = $all | Where-Object { $_.ProcessId -eq $current.ParentProcessId }
    }
    return $ids
}
$skipIds = Get-AncestorIds
$rootPrefix = $Root + '\'
$processes = @(Get-CimInstance Win32_Process | Where-Object {
    $skipIds -notcontains [int]$_.ProcessId -and (
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.CommandLine -and $_.CommandLine.IndexOf($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
         $_.Name -match '^(python|pythonw|pwsh|powershell|wscript|cscript|llama-server)\.exe$'))
})

# Bu kuruluma isaret eden masaustu kisayollari: MamidLabs.lnk ya da ikinci bir kurulum
# icin acilan "MamidLabs (<klasor>).lnk". Baska bir kopyanin kisayoluna dokunulmaz.
$shortcuts = @()
if (Test-Path -LiteralPath $DesktopPath -PathType Container) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($file in @(Get-ChildItem -LiteralPath $DesktopPath -Filter 'MamidLabs*.lnk' -File -ErrorAction SilentlyContinue)) {
        try {
            $link = $shell.CreateShortcut($file.FullName)
            if (($link.TargetPath + ' ' + $link.Arguments + ' ' + $link.WorkingDirectory).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $shortcuts += $file.FullName
            }
        } catch { }
    }
}

# Bu koke ait kaldirma kayitlari. Sihirbaz kaldiricisi kendi kaydini kendisi siler.
$registryKeys = @()
foreach ($base in $UninstallRegistryPaths) {
    if (!(Test-Path -LiteralPath $base)) { continue }
    foreach ($key in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if (!$props -or [string]$props.DisplayName -notlike 'MamidLabs*') { continue }
        if (([string]$props.InstallLocation).TrimEnd('\') -ine $Root) { continue }
        if ($FromWizard -and $key.PSChildName -like '*_is1') { continue }
        $registryKeys += $key.PSPath
    }
}

$sharedCaches = @()
if ($PurgeSharedCaches) {
    $sharedCaches = @((Join-Path $env:LOCALAPPDATA 'pip\cache'), (Join-Path $env:USERPROFILE '.cache\huggingface\xet'),
        (Join-Path $env:TEMP ('torchinductor_' + $env:USERNAME))) | Where-Object { Test-Path -LiteralPath $_ }
}

# ---------------------------------------------------------------- goster/onay
Write-Line ''
Write-Line 'MamidLabs kaldirma' 'White'
Write-Line "  kurulum klasoru: $Root"
Write-Line ''
if ($processes) { Write-Line '  Durdurulacak surecler:'; $processes | ForEach-Object { Write-Line ("    - " + $_.Name + " (" + $_.ProcessId + ")") } }
Write-Line '  Silinecek:'
$toDelete | ForEach-Object { Write-Line ("    - " + (Join-Path $Root $_)) }
$shortcuts | ForEach-Object { Write-Line "    - $_" }
$registryKeys | ForEach-Object { Write-Line ("    - kayit: " + ($_ -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')) }
$wingetPackages | ForEach-Object { Write-Line "    - winget paketi (MamidLabs kurdu): $_" }
$sharedCaches | ForEach-Object { Write-Line "    - paylasilan onbellek: $_" }
if ($KeepUserData) { Write-Line '  Kalacak: chats, outputs, settings (sohbetler, uretilen dosyalar, ayarlar)' 'DarkGray' }
if ($foreign) {
    Write-Line '  Klasorde MamidLabs disi girisler var (varsayilan olarak silinmez):' 'Yellow'
    $foreign | ForEach-Object { Write-Line ("    - " + (Join-Path $Root $_)) 'Yellow' }
}
Write-Line ''

if ($DryRun) { Write-Line 'Deneme modu (-DryRun): hicbir sey silinmedi.' 'Cyan'; exit 0 }

$deleteForeign = $false
if (!$Yes) {
    $answer = Read-Host 'Hepsi kalici olarak silinsin mi? (evet/hayir)'
    if ($answer -notmatch '^(e|evet|y|yes)$') { Write-Line 'Iptal edildi; hicbir sey silinmedi.' 'Yellow'; exit 0 }
    if ($foreign) {
        $answer = Read-Host 'MamidLabs disi girisler de silinsin mi? (evet/hayir)'
        $deleteForeign = $answer -match '^(e|evet|y|yes)$'
    }
}
if ($deleteForeign) { $toDelete += $foreign }

# -------------------------------------------------------------------- uygula
$failures = [Collections.Generic.List[string]]::new()

foreach ($process in $processes) {
    try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; Write-Line ("  [durduruldu] " + $process.Name) 'Green' }
    catch { if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) { $failures.Add("surec durdurulamadi: $($process.Name) ($($process.ProcessId))") } }
}
if ($processes) { Start-Sleep -Seconds 2 }

# Derin venv/ComfyUI yollari 260 karakteri asabilir; Remove-Item yetmezse rd kullanilir.
function Remove-Entry([string]$path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $path) {
            if (Test-Path -LiteralPath $path -PathType Container) { cmd.exe /d /c "rd /s /q `"\\?\$path`"" 2>$null | Out-Null }
            else { cmd.exe /d /c "del /f /q `"\\?\$path`"" 2>$null | Out-Null }
        }
        if (!(Test-Path -LiteralPath $path)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

foreach ($name in $toDelete) {
    $path = Join-Path $Root $name
    if (Remove-Entry $path) { Write-Line "  [silindi] $path" 'Green' } else { $failures.Add("silinemedi: $path") }
}
foreach ($shortcut in $shortcuts) {
    if (Remove-Entry $shortcut) { Write-Line "  [silindi] $shortcut" 'Green' } else { $failures.Add("silinemedi: $shortcut") }
}
foreach ($key in $registryKeys) {
    try { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop; Write-Line '  [silindi] Windows kaldirma kaydi' 'Green' }
    catch { $failures.Add("kayit silinemedi (yonetici gerekebilir): $key") }
}
foreach ($cache in $sharedCaches) {
    if (Remove-Entry $cache) { Write-Line "  [silindi] $cache" 'Green' } else { $failures.Add("silinemedi: $cache") }
}
foreach ($package in $wingetPackages) {
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (!$winget) { $failures.Add("winget yok; $package elle kaldirilmali"); continue }
    Write-Line "  winget ile kaldiriliyor: $package"
    & $winget uninstall --exact --id $package --silent --disable-interactivity --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -eq 0) { Write-Line "  [kaldirildi] $package" 'Green' } else { $failures.Add("winget $package kaldiramadi (cikis kodu $LASTEXITCODE)") }
}

# Kok bosaldiysa kendisi de silinir; MamidLabs disi dosya kaldiysa klasor yerinde kalir.
if (!$FromWizard -and (Test-Path -LiteralPath $Root) -and !(Get-ChildItem -LiteralPath $Root -Force)) {
    if (Remove-Entry $Root) { Write-Line "  [silindi] $Root" 'Green' } else { $failures.Add("silinemedi: $Root") }
}

Write-Line ''
if ($failures.Count) {
    Write-Line ("Kaldirma tamamlanamadi, " + $failures.Count + " sorun:") 'Red'
    $failures | ForEach-Object { Write-Line "  - $_" 'Red' }
    Write-Line 'Acik bir MamidLabs penceresi varsa kapatip betigi tekrar calistir.' 'Yellow'
} else {
    Write-Line 'MamidLabs kaldirildi.' 'Green'
}
if (!$Yes) { [void](Read-Host 'Kapatmak icin Enter') }
if ($failures.Count) { exit 1 }
exit 0
